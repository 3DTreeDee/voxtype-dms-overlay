#!/usr/bin/env python3
"""
auditor.py — Orquestador del Auditor de Reuniones.
Vigila el transcript de reuniones de voxtype en vivo, detecta enunciados nuevos
por cada lado (You / Remote), consulta la KB del vault (kb_index.py) y, si no
hay respuesta, consulta la IA (OmniRouteClient).

Salida: eventos JSON por línea (JSONL) lista para consumir desde el overlay QML
u otro proceso. Modo "realtime" observa el transcript vivo; modo "replay" una
transcripción ya guardada.
"""

import os
import sys
import json
import time
import argparse
import asyncio
import logging
import collections
from pathlib import Path
from typing import Dict, List, Optional, Iterator

from kb_index import KBIndex
from omniroute_client import OmniRouteClient, OmniRouteConfig, load_config_from_env_or_yaml

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("auditor")

# ---------------------------------------------------------------------------
# Eventos que emitimos (JSONL a stdout)
# ---------------------------------------------------------------------------
# {"type":"enunciado", "speaker":"you|remote", "text":"...", "ts":epoch}
# {"type":"kb_hit",   "speaker":"you", "text":"...", "sources":[{"file_path","score"}], "answer":"..."}
# {"type":"ai_answer","speaker":"you", "text":"...", "model":"...", "answer":"..."}
# {"type":"ai_error", "speaker":"you", "text":"...", "error":"..."}
# {"type":"info",     "msg":"..."}


def emit(evt: Dict):
    print(json.dumps(evt, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------------------
# Lector de transcript de voxtype
# ---------------------------------------------------------------------------
def meetings_index_path() -> Path:
    p = Path(os.environ.get("VOXTYPE_INDEX", "~/.local/share/voxtype/meetings/index.db"))
    return p.expanduser().resolve()


def iter_transcript_utterances(meeting_path: Path) -> Iterator[Dict]:
    """
    Devuelve utterances del transcript de una reunión de voxtype.
    Formato del archivo: lines tipo
       [HH:MM:SS] (speaker) texto
    Speaker puede ser "You" / "Remote" (o nombres reales si diarización).
    """
    if not meeting_path.exists():
        raise FileNotFoundError(f"Transcript no existe: {meeting_path}")

    with open(meeting_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            # Parsear [TS] (speaker) texto
            import re
            m = re.match(r"^\[([0-9:]+)\]\s*\(([^)]+)\)\s*(.*)$", line)
            if m:
                ts, speaker, text = m.groups()
                yield {
                    "ts": m.group(1),
                    "speaker": speaker.strip(),
                    "text": text.strip(),
                }
            else:
                # línea sin patrón — mantener como raw
                yield {"ts": None, "speaker": None, "text": line.strip()}


def infer_side(speaker: str) -> str:
    """Normaliza speaker a 'you' | 'remote'."""
    s = speaker.lower().strip()
    if s in ("you", "yo", "local", "mí"):
        return "you"
    if s in ("remote", "ellos", "otro", "guest"):
        return "remote"
    return "remote"  # default asumimos la otra parte


# ---------------------------------------------------------------------------
# Auditor principal
# ---------------------------------------------------------------------------
class MeetingAuditor:
    def __init__(self, kb: KBIndex, ai: OmniRouteClient, config: Optional[dict] = None):
        self.kb = kb
        self.ai = ai
        self.config = config or {}
        self.min_score = self.config.get("min_score", 0.35)
        self.kb_top_k = self.config.get("kb_top_k", 3)
        self.max_len = self.config.get("max_utterance_len", 400)
        # Fase 3: toggle respuestas automáticas (default OFF — solo captions)
        self.auto_reply = bool(self.config.get("auto_reply", False))
        self._last_seen_text: Optional[str] = None  # para dedupe en modo realtime
        # Historial conversacional para el modo RAG con IA: los últimos
        # enunciados (lado + texto) que dan contexto a las referencias
        # (eso, cómo se conecta, el último proyecto...) al refinar la
        # búsqueda y al redactar la respuesta.
        self._conversation = collections.deque(maxlen=12)

    # -- ¿IA configurada? (modo RAG vs. embeddings puros) --
    def _ai_configured(self) -> bool:
        return bool(self.ai) and bool(self.ai.config) and bool(self.ai.config.api_key)

    def _remember(self, side: str, text: str) -> None:
        self._conversation.append({"side": side, "text": text[:200]})

    def _conversation_block(self, max_items: int = 8) -> str:
        """Formatea el historial reciente como 'Tú: …' / 'Remoto: …'."""
        lines = []
        for item in list(self._conversation)[-max_items:]:
            who = "Tú" if item["side"] == "you" else "Remoto"
            lines.append(f"{who}: {item['text']}")
        return "\n".join(lines)

    @staticmethod
    def _parse_json_answer(raw: str) -> Optional[Dict]:
        """Extrae el primer objeto JSON de la respuesta del modelo (tolera
        texto alrededor y fences ```json)."""
        import re
        if not raw:
            return None
        m = re.search(r"\{.*\}", raw, re.S)
        if not m:
            return None
        try:
            data = json.loads(m.group(0))
            return data if isinstance(data, dict) else None
        except json.JSONDecodeError:
            return None

    # -- texto plano, sin speakers (para búsqueda KB) --
    def _build_kb_context(self, utterance: Dict) -> Optional[Dict]:
        """Busca la KB. Retorna None si no hay buen match, si no dict con fuentes."""
        text = utterance.get("text", "")
        if not text:
            return None
        results = self.kb.search(text, top_k=self.kb_top_k, min_score=self.min_score)
        if not results:
            return None
        # Construir respuesta basada en el mejor chunk
        best = results[0]
        answer = best["content"]
        return {
            "sources": [{"file_path": r["file_path"], "score": round(r["score"], 3)} for r in results],
            "answer": answer,
        }

    # -- Modo RAG con IA -------------------------------------------------------
    # Pipeline por enunciado:
    #   1) `_ai_decide_query`: la IA ve el contexto conversacional + el
    #      enunciado, decide si amerita respuesta y genera una query de
    #      búsqueda LIMPIA (resuelve referencias) → JSON {"answer": bool,
    #      "query": str}.
    #   2) búsqueda KB con esa query (umbral más laxo que el directo).
    #   3) `_ai_answer`: la IA redacta respuesta breve citando los archivos
    #      del vault (kb_hit 📚) o, si no hay nada relevante, responde con su
    #      propio conocimiento avisando que no está en las notas (ai_answer 💡).
    async def _ai_decide_query(self, side: str, text: str) -> Dict:
        convo = self._conversation_block(max_items=8)
        system = (
            "Eres el analizador de un asistente de reunión. Recibes el contexto "
            "de una conversación y el enunciado MÁS RECIENTE. Decide si ese "
            "enunciado es una pregunta o un pedido de información que merece "
            "consultar la base de conocimiento del usuario. "
            "Responde ÚNICAMENTE con JSON: {\"answer\": true|false, \"query\": \"...\"} "
            "- answer=false para saludos, muletillas, afirmaciones sin pedir info. "
            "- query: frase corta (5-15 palabras) que capture QUÉ se pregunta, "
            "resolviendo referencias del contexto (p.ej. \"eso\", \"el proyecto\", "
            "\"cómo se conecta\") en términos concretos. Si answer=false, query=\"\"."
        )
        user = (
            f"Contexto de la reunión:\n{convo}\n\n"
            f"Enunciado más reciente ({'Tú' if side == 'you' else 'Remoto'}): "
            f"\"{text}\"\n\nJSON:"
        )
        raw = await self.ai.chat_completion(
            [{"role": "system", "content": system},
             {"role": "user", "content": user}],
            task="kb_fallback", temperature=0.0, max_tokens=160)
        data = self._parse_json_answer(raw) or {}
        return {
            "answer": bool(data.get("answer", True)),
            "query": (data.get("query") or "").strip()[:200],
        }

    async def _ai_answer(self, side: str, text: str, results: List[Dict]) -> str:
        convo = self._conversation_block(max_items=6)
        who = "Tú" if side == "you" else "Remoto"
        if results:
            chunks = "\n".join(
                f"[{r['score']:.2f}] {r['file_path']}: {r['content'][:400]}"
                for r in results[:4])
            system = (
                "Eres un asistente dentro de una reunión. El usuario te pide "
                "información y tienes notas de su vault de Obsidian. Responde de "
                "forma breve (máx 90 palabras) y accionable, en el idioma del "
                "enunciado. Usa SOLO la información de las notas; si no responde "
                "la pregunta, dilo y no inventes. Cita los archivos relevantes "
                "al final como: Fuentes: nombre1.md, nombre2.md (solo nombres)."
            )
            user = (
                f"Contexto de la reunión:\n{convo}\n\n"
                f"{who}: \"{text}\"\n\n"
                f"Notas relevantes del vault:\n{chunks}\n\nRespuesta:"
            )
        else:
            system = (
                "Eres un asistente dentro de una reunión. Te piden información "
                "que NO está en las notas del vault del usuario. Responde de "
                "forma breve (máx 90 palabras) y accionable, en el idioma del "
                "enunciado. Empieza dejando claro que no está en sus notas "
                "(p.ej. \"No lo tengo en tus notas, pero…\") y luego ayuda con "
                "tu conocimiento general. No inventes datos de las notas."
            )
            user = (
                f"Contexto de la reunión:\n{convo}\n\n"
                f"{who}: \"{text}\"\n\n"
                "(No hay chunks relevantes en el vault.)\n\nRespuesta:"
            )
        return await self.ai.chat_completion(
            [{"role": "system", "content": system},
             {"role": "user", "content": user}],
            task="kb_fallback", temperature=0.2, max_tokens=500)

    async def _process_with_ai(self, evt_base: Dict, side: str, text: str) -> None:
        """Pipeline RAG: IA decide/refina → KB → IA redacta citando (o responde
        con conocimiento propio si el vault no tiene nada)."""
        try:
            decision = await self._ai_decide_query(side, text)
            if not decision.get("answer", True):
                log.info(f"IA: sin respuesta para [{side}] \"{text[:60]}\"")
                return
            query = decision.get("query") or text
            # Umbral más laxo que la búsqueda directa: la query ya viene
            # refinada por la IA, así que incluso un match moderado es útil
            # como contexto para la respuesta.
            results = self.kb.search(query, top_k=5, min_score=0.20)
            log.info(f"IA: query=\"{query[:80]}\" → {len(results)} chunk(s) KB")
            answer = await self._ai_answer(side, text, results)
            if not answer or not answer.strip():
                log.warning("IA devolvió respuesta vacía")
                return
            if results:
                emit({
                    **evt_base,
                    "type": "kb_hit",
                    "sources": [{"file_path": r["file_path"], "score": round(r["score"], 3)}
                                for r in results[:4]],
                    "answer": answer.strip()[:900],
                })
            else:
                emit({
                    **evt_base,
                    "type": "ai_answer",
                    "model": self.ai.config.get_model("kb_fallback").name,
                    "answer": answer.strip()[:900],
                })
        except Exception as e:
            log.warning(f"IA RAG error: {e}")
            emit({**evt_base, "type": "ai_error", "error": str(e)[:300]})

    async def process_utterance(self, utterance: Dict) -> None:
        """Procesa UN enunciado: con IA configurada → pipeline RAG (IA decide,
        busca en el vault y responde citando o con conocimiento propio); sin IA
        → búsqueda KB directa clásica (kb_hit con el fragmento)."""
        speaker_raw = utterance.get("speaker", "Remote")
        side = infer_side(speaker_raw)
        text = utterance.get("text", "").strip()
        if not text:
            return

        evt_base = {"speaker": side, "speaker_raw": speaker_raw, "text": text, "ts": utterance.get("ts")}
        emit({**evt_base, "type": "enunciado"})
        self._remember(side, text)

        # Fase 3: si auto_reply está OFF, solo emitimos captions (sin IA/KB)
        if not self.auto_reply:
            log.debug(f"[{side}] caption-only: {text[:80]}")
            return

        if self._ai_configured():
            await self._process_with_ai(evt_base, side, text)
            return

        # --- Sin IA: búsqueda KB directa (comportamiento clásico) ---
        # 1) Buscar en KB
        kb_context = self._build_kb_context(utterance)
        if kb_context:
            emit({
                **evt_base,
                "type": "kb_hit",
                "sources": kb_context["sources"],
                "answer": kb_context["answer"][:600],
            })
            return

        # 2) Fallback IA
        try:
            messages = self._build_messages_for_ai(utterance, kb_context)
            answer = await self.ai.chat_completion(messages, task="kb_fallback")
            emit({
                **evt_base,
                "type": "ai_answer",
                "model": self.ai.config.get_model("kb_fallback").name,
                "answer": answer,
            })
        except Exception as e:
            log.warning(f"IA fallback error: {e}")
            emit({**evt_base, "type": "ai_error", "error": str(e)})

    def _build_messages_for_ai(self, utterance: Dict, kb_context: Optional[Dict] = None) -> List[Dict]:
        """Construye system+user para la tarea IA de fallback."""
        side = utterance.get("speaker", "remote")
        side_label = "el usuario (Tú)" if side == "you" else "la otra persona (Remoto)"
        text = utterance.get("text", "")
        system = (
            "Eres un asistente de apoyo en una reunión técnica. Recibes un enunciado "
            "y debes responder de forma breve y útil: aclarar, sugerir, corregir o dar "
            "información relevante. Responde en español salvo que el tema sea ingés.Conserva tecnicismos."
        )
        user = f"Enunciado de {side_label}: \"{text}\""
        if kb_context:
            user += (
                "\n\nContexto relevante de la base de conocimiento (puedes citarlo):\n"
                + "\n".join(f"- {s['file_path']}: {s['answer'][:300]}" for s in [kb_context])
            )
        user += "\n\nDa una respuesta breve (máx 100 palabras) y accionable."
        return [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ]

    # -- Realtime: vigilar un archivo de transcript creciente --
    async def watch_transcript(self, transcript_path: Path, poll_interval: float = 1.0) -> None:
        """POLANG: mira el transcript, procesa utterances nuevos del final."""
        log.info(f"Vigilando {transcript_path}")
        last_bytes = 0
        try:
            while True:
                size = transcript_path.stat().st_size
                if size > last_bytes:
                    with open(transcript_path, "r", encoding="utf-8") as f:
                        f.seek(last_bytes)
                        new_data = f.read()
                    last_bytes = size
                    # Parsear utterances de la porción nueva
                    for line in new_data.splitlines():
                        utterance = self._parse_line(line)
                        if utterance:
                            await self.process_utterance(utterance)
                await asyncio.sleep(poll_interval)
        except FileNotFoundError:
            log.error(f"Transcript desapareció: {transcript_path}")
        except KeyboardInterrupt:
            log.info("Detenido por el usuario")

    def _parse_line(self, line: str) -> Optional[Dict]:
        import re
        m = re.match(r"^\[([0-9:]+)\]\s*\(([^)]+)\)\s*(.*)$", line)
        if not m:
            if line.strip():
                return {"ts": None, "speaker": "Remote", "text": line.strip()}
            return None
        ts, speaker, text = m.groups()
        if not text.strip():
            return None
        return {"ts": ts, "speaker": speaker, "text": text.strip()}

    # -- Replay: leer un transcript ya guardado --
    async def replay_transcript(self, transcript_path: Path) -> None:
        log.info(f"Replay {transcript_path}")
        for utt in iter_transcript_utterances(transcript_path):
            if utt.get("text"):
                await self.process_utterance(utt)

    # -- Watch del transcript.json nativo de voxtype (formato JSON segments[]) --
    @staticmethod
    def _find_active_transcript() -> Optional[Path]:
        """Devuelve el transcript.json más reciente de ~/.local/share/voxtype/meetings."""
        base = Path.home() / ".local/share/voxtype/meetings"
        if not base.exists():
            return None
        cands = sorted(base.glob("*/transcript.json"),
                       key=lambda p: p.stat().st_mtime, reverse=True)
        return cands[0] if cands else None

    async def watch_json(self, transcript_path: Optional[Path],
                         poll_interval: float = 1.0) -> None:
        """Vigila el transcript.json nativo de voxtype (segments[]), procesando
        segments nuevos (id creciente). Si no se da path, auto-detecta el
        transcript más reciente (la reunión activa)."""
        last_seen_id = -1
        last_path: Optional[Path] = None
        log.info(f"Vigilando transcript.json (auto-detect activo: {transcript_path is None})")
        while True:
            path = transcript_path
            if path is None or not path.exists():
                path = self._find_active_transcript()
            if path is not None and path.exists():
                # Si cambió de archivo (nueva reunión), resetear dedupe
                if last_path != path:
                    last_path = path
                    last_seen_id = -1
                    log.info(f"Transcript activo: {path}")
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                    segments = data.get("segments", []) if isinstance(data, dict) else []
                except Exception:
                    segments = []
                for seg in segments:
                    try:
                        sid = int(seg.get("id", -1))
                    except (TypeError, ValueError):
                        sid = -1
                    if sid <= last_seen_id:
                        continue
                    text = (seg.get("text") or "").strip()
                    if not text:
                        last_seen_id = max(last_seen_id, sid)
                        continue
                    last_seen_id = max(last_seen_id, sid)
                    source = seg.get("source", "microphone")
                    speaker = seg.get("speaker_id") or (
                        "You" if source == "microphone" else "Remote")
                    await self.process_utterance({
                        "speaker": speaker,
                        "ts": seg.get("start_ms"),
                        "text": text,
                    })
            await asyncio.sleep(poll_interval)

    # -- Capture en vivo: grabar mic + loopback y transcribir con voxtype --
    async def capture_live(self, chunk_secs: float = 6.0,
                           mic_source: Optional[str] = None,
                           loop_source: Optional[str] = None,
                           vad_threshold: float = 0.003) -> None:
        """Feed 100% en vivo: captura audio (mic → You, loopback → Remote),
        transcribe cada chunk con `voxtype transcribe` (modelo residente en el
        daemon de voxtype) y procesa los enunciados con KB/IA."""
        from audio_capture import LiveCapture, _default_mic_source, _default_loopback_source

        voxtype_bin = self._resolve_voxtype()
        if not voxtype_bin:
            log.error("voxtype no está en PATH; el modo capture lo necesita")
            emit({"type": "ai_error", "speaker": "you", "text": "",
                  "error": "voxtype CLI no encontrado en PATH"})
            return

        cap = LiveCapture(chunk_secs=chunk_secs,
                          mic_source=mic_source or _default_mic_source(),
                          loop_source=loop_source or _default_loopback_source(),
                          vad_threshold=vad_threshold)
        await cap.start()

        log.info(f"Capture en vivo activo (chunk={chunk_secs}s, umbral VAD={vad_threshold})")
        transcribe_tasks: Dict[str, asyncio.Task] = {}
        last_finish: Dict[str, float] = {}   # dedupe: texto repetido en <2 chunks

        try:
            while True:
                chunk = await cap.next_chunk()
                if chunk is None:
                    break
                # Lanzar transcripción de mic y loop en paralelo
                if chunk.mic_wav is not None:
                    transcribe_tasks["you"] = asyncio.create_task(
                        self._transcribe_and_process(
                            voxtype_bin, chunk.mic_wav, "you", "You", last_finish))
                if chunk.loop_wav is not None:
                    transcribe_tasks["remote"] = asyncio.create_task(
                        self._transcribe_and_process(
                            voxtype_bin, chunk.loop_wav, "remote", "Remote", last_finish))
                # Esperar a que terminen antes del siguiente chunk (evita GPU saturada)
                if transcribe_tasks:
                    done, pending = await asyncio.wait(
                        transcribe_tasks.values(), timeout=chunk_secs + 20)
                    for t in pending:
                        t.cancel()
                    transcribe_tasks = {k: v for k, v in transcribe_tasks.items()
                                        if not v.done()}
                    # limpiar tasks completadas
                    transcribe_tasks = {}
        finally:
            await cap.stop()

    @staticmethod
    def _resolve_voxtype() -> Optional[str]:
        import shutil
        for cand in (shutil.which("voxtype"),
                     str(Path.home() / ".local/bin/voxtype"),
                     "/usr/bin/voxtype"):
            if cand and os.path.exists(cand):
                return cand
        return None

    async def _transcribe_and_process(self, voxtype_bin: str, wav: Path,
                                      side: str, speaker_raw: str,
                                      last_finish: Dict[str, float]) -> None:
        """Transcribe un WAV con `voxtype transcribe` y procesa el enunciado."""
        try:
            text = await self._transcribe_wav(voxtype_bin, wav)
        except Exception as e:
            log.warning(f"Transcripción falló: {e}")
            return
        text = (text or "").strip()
        if not text or len(text) < 2:
            return
        # Dedupe: mismo texto terminado hace <2*chunk (evita repetir por solape)
        now = time.time()
        if last_finish.get(side) and now - last_finish[side] < self.chunk_dedupe_secs:
            return
        last_finish[side] = now
        log.info(f"[{side}] {text[:100]}")
        await self.process_utterance({
            "speaker": side,
            "speaker_raw": speaker_raw,
            "text": text,
            "ts": int(now * 1000),
        })

    @property
    def chunk_dedupe_secs(self) -> float:
        return getattr(self, "_chunk_dedupe_secs", 8.0)

    async def _transcribe_wav(self, voxtype_bin: str, wav: Path) -> str:
        """Invoca `voxtype transcribe <wav>`; devuelve el texto transcrito.

        voxtype imprime logs INFO coloreados (ANSI) a stdout; el texto real va
        en la línea 'Transcription completed in Xs: "..."'. Cualquier otra cosa
        (progreso, 'Model loaded', etc.) NO es transcripción: devolvemos ''.
        """
        import re
        ansi_re = re.compile(r"\x1b\[[0-9;]*m")
        proc = await asyncio.create_subprocess_exec(
            voxtype_bin, "transcribe", str(wav),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
        text = ""
        for raw in out.decode("utf-8", "replace").splitlines():
            line = ansi_re.sub("", raw)  # quitar códigos de color
            m = re.search(r'Transcription completed in .*?:\s*["“](.+?)["”]\s*$', line)
            if m:
                text = m.group(1).strip()
        return text


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
async def main():
    parser = argparse.ArgumentParser(description="Auditor de reuniones (KB + OmniRoute fallback)")
    sub = parser.add_subparsers(dest="cmd")

    p_replay = sub.add_parser("replay", help="Procesar un transcript ya guardado")
    p_replay.add_argument("transcript", help="Path al transcript .md")

    p_watch = sub.add_parser("watch", help="Vigilar un transcript creciente en vivo")
    p_watch.add_argument("transcript")
    p_watch.add_argument("--poll", type=float, default=1.0)

    p_watch_json = sub.add_parser("watch-json", help="Vigilar el transcript.json nativo de voxtype (auto-detecta reunión activa)")
    p_watch_json.add_argument("transcript", nargs="?", default=None,
                              help="Path opcional a un transcript.json concreto")
    p_watch_json.add_argument("--poll", type=float, default=1.0)

    p_capture = sub.add_parser("capture", help="Captura audio en vivo (mic+loopback) y transcribe con voxtype (feed 100% en vivo)")
    p_capture.add_argument("--chunk-secs", type=float, default=6.0)
    p_capture.add_argument("--mic-source", default=None, help="Source PipeWire del mic (default: source del sistema)")
    p_capture.add_argument("--loop-source", default=None, help="Monitor del sink (default: monitor del sink por defecto)")
    p_capture.add_argument("--vad-threshold", type=float, default=0.003)

    p_server = sub.add_parser("listen", help="Escuchar eventos via stdin (para el QML)")

    common = parser.add_argument_group("Común")
    common.add_argument("--vault", default=os.environ.get("VOXTYPE_VAULT",
                        str(Path.home() / "Documentos/vault")))
    common.add_argument("--kb-db", help="Path al SQLite index de KB (opcional)")
    common.add_argument("--config", help="Path a config.yaml (OmniRoute)")
    common.add_argument("--min-score", type=float, default=0.35)

    args = parser.parse_args()

    if not args.cmd:
        parser.print_help()
        sys.exit(1)

    # Init dependencias
    vault_path = Path(args.vault).expanduser()
    if args.vault in (None, "", "null", "None") or not vault_path.is_dir():
        log.error(f"Vault inválido: {args.vault!r} — usando default {Path.home() / 'Documentos/vault'}")
        args.vault = str(Path.home() / "Documentos/vault")
    kb = KBIndex(args.vault, args.kb_db)
    # Indexar si no existe (primera vez)
    if not Path(kb.db_path).exists():
        log.info("Primera ejecución: indexando vault...")
        kb.index_vault()

    ai_cfg = load_config_from_env_or_yaml(args.config)
    auto_reply = os.environ.get("AUDITOR_AUTO_REPLY", "").lower() in ("true", "1", "yes")
    auditor = MeetingAuditor(kb, None, {"min_score": args.min_score, "auto_reply": auto_reply})

    if args.cmd == "replay":
        # Replay: usar IA async si se pide (transcripción ya guardada)
        async with OmniRouteClient(ai_cfg) as ai:
            auditor.ai = ai
            await auditor.replay_transcript(Path(args.transcript))
    elif args.cmd == "watch":
        async with OmniRouteClient(ai_cfg) as ai:
            auditor.ai = ai
            await auditor.watch_transcript(Path(args.transcript), args.poll)
    elif args.cmd == "watch-json":
        async with OmniRouteClient(ai_cfg) as ai:
            auditor.ai = ai
            await auditor.watch_json(Path(args.transcript) if args.transcript else None,
                                     args.poll)
    elif args.cmd == "capture":
        async with OmniRouteClient(ai_cfg) as ai:
            auditor.ai = ai
            await auditor.capture_live(chunk_secs=args.chunk_secs,
                                       mic_source=args.mic_source,
                                       loop_source=args.loop_source,
                                       vad_threshold=args.vad_threshold)
    elif args.cmd == "listen":
        # Modo server: leer JSON de enunciados por stdin
        async with OmniRouteClient(ai_cfg) as ai:
            auditor.ai = ai
            log.info("Escuchando enunciados por stdin (JSON por línea)...")
            loop = asyncio.get_event_loop()
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    utt = json.loads(line)
                except json.JSONDecodeError:
                    continue
                await auditor.process_utterance(utt)


if __name__ == "__main__":
    asyncio.run(main())