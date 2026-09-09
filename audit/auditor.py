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
        # Fase 4/5: toggle vault search y umbral de similitud
        self.vault_search = bool(self.config.get("vault_search", True))
        self.kb_threshold = float(self.config.get("kb_threshold", 0.70))
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
                "información. Tienes notas de su vault de Obsidian que PODRÍAN "
                "ser relevantes. Evalúa si realmente responden la pregunta. "
                "Si las notas son relevantes, responde citándolas (máx 90 "
                "palabras) e incluye 'Fuentes: nombre1.md' al final. "
                "Si las notas NO responden la pregunta o son irrelevantes, "
                "IGNÓRALAS y responde con tu conocimiento general (pero "
                "sin inventar datos del vault). Responde en el idioma del "
                "enunciado."
            )
            user = (
                f"Contexto de la reunión:\n{convo}\n\n"
                f"{who}: \"{text}\"\n\n"
                f"Notas del vault:\n{chunks}\n\n"
                "Respuesta (si las notas no sirven, ignóralas):"
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

    # -- Capture en vivo (Fase 6): frases por VAD + whisper-server persistente --
    async def capture_live(self, mic_source: Optional[str] = None,
                           loop_source: Optional[str] = None,
                           vad_threshold: float = 0.003,
                           min_silence_secs: float = 0.8,
                           max_phrase_secs: float = 15.0,
                           whisper_url: Optional[str] = None) -> None:
        """Feed en vivo por FRASES (Fase 6): captura continua (mic → You,
        loopback → Remote) con corte por fin-de-frase (VAD), transcribe cada
        frase con el whisper-server HTTP persistente (modelo caliente en VRAM,
        ~0.4-0.7s/frase) y emite captions. Push-to-ask (Fase 4) intacto: señal
        ask_start/ask_end → graba aparte → transcribe (whisper-server) → IA
        con contexto de los últimos captions."""
        from audio_capture import LiveCapture, _default_mic_source, _default_loopback_source

        # Motor de transcripción: whisper-server persistente. Si no puede
        # arrancar, caemos a `voxtype transcribe` (lento pero funcional).
        whisper = WhisperHTTP(url=whisper_url)
        ok = await whisper.ensure()
        if not ok:
            log.warning("whisper-server no disponible — usando voxtype transcribe (lento)")
            emit({"type": "info",
                  "msg": "⚠️ Motor whisper-server no disponible; usando voxtype (más lento)"})
        self._whisper = whisper
        self._transcribe_engine = whisper if ok else None

        cap = LiveCapture(mic_source=mic_source or _default_mic_source(),
                          loop_source=loop_source or _default_loopback_source(),
                          vad_threshold=vad_threshold,
                          min_silence_secs=min_silence_secs,
                          max_phrase_secs=max_phrase_secs)
        await cap.start()

        log.info(f"Capture por frases activo (silencio≥{min_silence_secs}s, "
                 f"tope={max_phrase_secs}s, umbral VAD={vad_threshold})")

        # ── Push-to-ask (Fase 4) ────────────────────────────────────────────
        ask_dir = cap.tmp_dir
        ask_cmd_file = ask_dir / "ask.cmd"
        ask_dir.mkdir(parents=True, exist_ok=True)
        self._ask_buffering = False
        self._ask_procs: List[asyncio.subprocess.Process] = []   # subprocesses pw-record
        self._ask_wavs: Dict[str, Path] = {}

        async def _watch_ask_commands():
            """Vigila ask.cmd cada 200ms para comandos ask_start / ask_end."""
            while True:
                try:
                    if ask_cmd_file.exists():
                        cmd = ask_cmd_file.read_text("utf-8").strip().lower()
                        if cmd.startswith("ask_start") and not self._ask_buffering:
                            await _start_ask_buffer()
                        elif cmd.startswith("ask_end") and self._ask_buffering:
                            await _end_ask_buffer()
                        # Limpiar el archivo tras procesar
                        if cmd:
                            ask_cmd_file.write_text("")
                except Exception:
                    pass
                await asyncio.sleep(0.2)

        async def _start_ask_buffer():
            """Inicia grabación raw para push-to-ask (mic + loopback)."""
            self._ask_buffering = True
            self._ask_procs = []
            ts = int(time.time())
            log.info("🎤 Push-to-ask INICIO")
            emit({"type": "info", "msg": "🎤 Preguntando… habla ahora"})
            import shutil
            pw = shutil.which("pw-record")
            if pw:
                sr = 16000
                for tag, src in [("mic", cap.mic_source),
                                 ("loop", cap.loop_source)]:
                    if not src:
                        continue
                    out = ask_dir / f"ask_{ts}_{tag}.wav"
                    self._ask_wavs[tag] = out
                    cmd = [pw, "--target", src, "--rate", str(sr),
                           "--channels", "1", "--format", "s16",
                           "--latency", "100ms", str(out)]
                    try:
                        proc = await asyncio.create_subprocess_exec(
                            *cmd, stdout=asyncio.subprocess.DEVNULL,
                            stderr=asyncio.subprocess.DEVNULL)
                        self._ask_procs.append(proc)
                    except Exception as e:
                        log.warning(f"ask {tag} falló: {e}")

        async def _end_ask_buffer():
            """Detiene grabación, transcribe y envía a IA."""
            self._ask_buffering = False
            log.info("🎤 Push-to-ask FIN — transcribiendo…")
            emit({"type": "info", "msg": "💭 Pensando…"})
            # Matar procesos de grabación
            for p in self._ask_procs:
                try:
                    p.terminate()
                    await asyncio.wait_for(p.wait(), timeout=3)
                except Exception:
                    try:
                        p.kill()
                    except Exception:
                        pass
            self._ask_procs = []
            # Esperar pequeños WAVs se terminen de escribir
            await asyncio.sleep(0.5)
            # Transcribir cada lado
            mic_text = ""
            loop_text = ""
            for tag, wav in self._ask_wavs.items():
                if wav and wav.exists() and wav.stat().st_size > 2000:
                    try:
                        text = await self._ask_transcribe(wav)
                        if text and text.strip():
                            if tag == "mic":
                                mic_text = text.strip()
                            else:
                                loop_text = text.strip()
                    except Exception as e:
                        log.warning(f"ask transcribe {tag}: {e}")
                    finally:
                        # Limpiar WAV temporal
                        try:
                            wav.unlink(missing_ok=True)
                        except Exception:
                            pass
            # Construir texto combinado
            combined = []
            if mic_text:
                combined.append(f"Tú: {mic_text}")
            if loop_text:
                combined.append(f"Remoto: {loop_text}")
            ask_text = " | ".join(combined) if combined else ""
            if not ask_text:
                log.info("Push-to-ask: silencio o transcripción vacía")
                emit({"type": "info", "msg": "No se detectó voz durante la pulsación."})
                return
            # Contexto de la reunión (últimos captions)
            convo = self._conversation_block(max_items=10)
            prompt = (
                f"Contexto de la reunión (últimos mensajes):\n{convo}\n\n"
                f"Pregunta capturada:\n{ask_text}\n\n"
                "Responde la pregunta usando el vault de Obsidian o tu conocimiento."
            )
            log.info(f"Push-to-ask: {ask_text[:120]}")
            # Ejecutar RAG con IA: buscar en KB y responder
            evt_base = {"speaker": "you", "speaker_raw": "You",
                        "text": ask_text, "ts": int(time.time() * 1000)}
            if self._ai_configured():
                try:
                    results = self.kb.search(ask_text, top_k=5, min_score=0.20)
                    answer = await self._ai_answer("you", ask_text, results)
                    if answer and answer.strip():
                        if results:
                            emit({**evt_base, "type": "kb_hit",
                                  "sources": [{"file_path": r["file_path"],
                                               "score": round(r["score"], 3)}
                                              for r in results[:4]],
                                  "answer": answer.strip()[:900]})
                        else:
                            emit({**evt_base, "type": "ai_answer",
                                  "model": self.ai.config.get_model("kb_fallback").name,
                                  "answer": answer.strip()[:900]})
                except Exception as e:
                    log.warning(f"ask AI error: {e}")
                    emit({**evt_base, "type": "ai_error", "error": str(e)[:300]})
            else:
                # Sin IA: búsqueda KB directa
                kb_result = self._build_kb_context({"text": ask_text})
                if kb_result:
                    emit({**evt_base, "type": "kb_hit",
                          "sources": kb_result["sources"],
                          "answer": kb_result["answer"][:600]})
                else:
                    emit({**evt_base, "type": "ai_error",
                          "error": "IA no configurada y KB sin resultados."})

        # Arrancar vigía de comandos push-to-ask en paralelo
        ask_watcher = asyncio.create_task(_watch_ask_commands())

        async def _ask_transcribe(wav: Path) -> str:
            """Transcribe un WAV con el motor activo (whisper-server o voxtype)."""
            if self._transcribe_engine is not None:
                return await self._transcribe_engine.transcribe(wav)
            vb = self._resolve_voxtype()
            if vb:
                return await self._transcribe_wav(vb, wav)
            return ""

        # helper de transcripción compartido por captions y push-to-ask
        async def _transcribe(wav: Path, side: str, speaker_raw: str) -> None:
            try:
                if self._transcribe_engine is not None:
                    text = await self._transcribe_engine.transcribe(wav)
                else:
                    vb = self._resolve_voxtype()
                    if not vb:
                        return
                    text = await self._transcribe_wav(vb, wav)
            except Exception as e:
                log.warning(f"Transcripción falló: {e}")
                return
            text = (text or "").strip()
            if not text or len(text) < 2:
                return
            log.info(f"[{side}] {text[:100]}")
            await self.process_utterance({
                "speaker": side,
                "speaker_raw": speaker_raw,
                "text": text,
                "ts": int(time.time() * 1000),
            })

        try:
            while True:
                chunk = await cap.next_chunk()
                if chunk is None:
                    break
                # Transcribir los lados con frase cerrada en paralelo
                tasks = []
                if chunk.mic_wav is not None:
                    tasks.append(asyncio.create_task(
                        _transcribe(chunk.mic_wav, "you", "You")))
                if chunk.loop_wav is not None:
                    tasks.append(asyncio.create_task(
                        _transcribe(chunk.loop_wav, "remote", "Remote")))
                if tasks:
                    await asyncio.gather(*tasks, return_exceptions=True)
        finally:
            ask_watcher.cancel()
            await cap.stop()
            await whisper.close()

    # -- Live meeting: captions rápidos desde transcript.json de voxtype --
    async def live_meeting(self, transcript_path: Optional[Path] = None,
                           poll_interval: float = 0.5) -> None:
        """Modo reunión en vivo: lee el transcript.json que voxtype genera
        en tiempo real (segmentos cada ~2-3s) y los muestra como captions.
        Push-to-ask: recibe comandos via ask.cmd, recolecta segmentos del
        lapso de la pulsación (texto ya transcrito, sin grabar audio)."""
        last_seen_id = -1
        last_path: Optional[Path] = None
        running_meeting = True
        log.info("Modo live: vigilando transcript.json (captions rápidos + push-to-ask)")

        # ── Push-to-ask: solo texto, sin pw-record ─────────────────────────
        ask_dir = Path("/tmp/voxtype-auditor")
        ask_cmd_file = ask_dir / "ask.cmd"
        ask_dir.mkdir(parents=True, exist_ok=True)
        self._ask_buffering = False
        self._ask_start_id = -1   # último segment ID visto al presionar
    
        def _collect_ask_text(segments: List[Dict], since_id: int) -> str:
            """Recolecta texto de segmentos con id > since_id."""
            parts = []
            for seg in segments:
                try:
                    sid = int(seg.get("id", -1))
                except (TypeError, ValueError):
                    continue
                if sid > since_id:
                    text = (seg.get("text") or "").strip()
                    if text:
                        parts.append(text)
            return " ".join(parts) if parts else ""

        async def _watch_ask_commands():
            """Vigila ask.cmd cada 200ms: ask_start marca tiempo, ask_end
            recolecta segmentos y ejecuta RAG."""
            while running_meeting:
                try:
                    if ask_cmd_file.exists():
                        cmd = ask_cmd_file.read_text("utf-8").strip().lower()
                        if cmd.startswith("ask_start") and not self._ask_buffering:
                            self._ask_buffering = True
                            self._ask_start_id = last_seen_id
                            log.info("🎤 Push-to-ask INICIO")
                            emit({"type": "info", "msg": "🎤 Preguntando… habla ahora"})
                        elif cmd.startswith("ask_end") and self._ask_buffering:
                            self._ask_buffering = False
                            log.info("🎤 Push-to-ask FIN — consultando IA…")
                            emit({"type": "info", "msg": "💭 Pensando…"})
                            # Esperar un poco para que lleguen segmentos pendientes
                            await asyncio.sleep(1.5)
                            # Recolectar texto de segmentos desde ask_start_id
                            ask_text = ""
                            if path and path.exists():
                                try:
                                    data = json.loads(path.read_text("utf-8"))
                                    segs = data.get("segments", []) if isinstance(data, dict) else []
                                    ask_text = _collect_ask_text(segs, self._ask_start_id)
                                except Exception:
                                    pass
                            if not ask_text:
                                log.info("Push-to-ask: sin segmentos nuevos")
                                emit({"type": "info", "msg": "No se detectó voz durante la pulsación."})
                            else:
                                log.info(f"Push-to-ask: \"{ask_text[:120]}\"")
                                evt_base = {"speaker": "you", "speaker_raw": "You",
                                            "text": ask_text, "ts": int(time.time() * 1000)}
                                await self._execute_ask_rag(evt_base, ask_text)
                        if cmd:
                            ask_cmd_file.write_text("")
                except Exception:
                    pass
                await asyncio.sleep(0.2)

        async def _execute_ask_rag(evt_base: Dict, ask_text: str) -> None:
            """Ejecuta RAG para push-to-ask: busca vault si está habilitado,
            IA decide relevancia y responde."""
            if self._ai_configured():
                results = []
                if self.vault_search:
                    results = self.kb.search(ask_text, top_k=5, min_score=self.kb_threshold)
                answer = await self._ai_answer("you", ask_text, results)
                if answer and answer.strip():
                    if results:
                        emit({**evt_base, "type": "kb_hit",
                              "sources": [{"file_path": r["file_path"],
                                           "score": round(r["score"], 3)}
                                          for r in results[:4]],
                              "answer": answer.strip()[:900]})
                    else:
                        emit({**evt_base, "type": "ai_answer",
                              "model": self.ai.config.get_model("kb_fallback").name,
                              "answer": answer.strip()[:900]})
            else:
                # Sin IA: búsqueda KB directa
                if self.vault_search:
                    kb_result = self._build_kb_context({"text": ask_text})
                    if kb_result:
                        emit({**evt_base, "type": "kb_hit",
                              "sources": kb_result["sources"],
                              "answer": kb_result["answer"][:600]})
                        return
                emit({**evt_base, "type": "ai_error",
                      "error": "IA no configurada y sin resultados del vault."})

        # Arrancar watcher de push-to-ask
        ask_watcher = asyncio.create_task(_watch_ask_commands())

        try:
            while running_meeting:
                path = transcript_path
                if path is None or not path.exists():
                    path = self._find_active_transcript()
                if path is not None and path.exists():
                    if last_path != path:
                        last_path = path
                        last_seen_id = -1
                        log.info(f"Transcript activo: {path}")
                    try:
                        data = json.loads(path.read_text("utf-8"))
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
                        # Emitir caption
                        await self.process_utterance({
                            "speaker": speaker,
                            "ts": seg.get("start_ms"),
                            "text": text,
                        })
                await asyncio.sleep(poll_interval)
        finally:
            ask_watcher.cancel()
            log.info("Modo live finalizado")

    @staticmethod
    def _resolve_voxtype() -> Optional[str]:
        import shutil
        for cand in (shutil.which("voxtype"),
                     str(Path.home() / ".local/bin/voxtype"),
                     "/usr/bin/voxtype"):
            if cand and os.path.exists(cand):
                return cand
        return None

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
# Motor de transcripción Fase 6: whisper-server HTTP persistente (Vulkan)
# ---------------------------------------------------------------------------
# whisper.cpp compilado con GGML_VULKAN=ON trae `whisper-server`: carga el
# modelo ggml-large-v3-turbo UNA vez en VRAM (~1.6GB) y responde en
# ~400-660ms por transcripción con modelo caliente (vs ~4.3s de `voxtype
# transcribe` que recarga el modelo por invocación). Instalado en
# ~/.local/share/whisper-cpp/ (cmake --install). El rpath queda vacío al
# instalar → lanzar con LD_LIBRARY_PATH apuntando a su lib/.


class WhisperHTTP:
    """Cliente + ciclo de vida del whisper-server.

    - ensure(): health check; si no responde, lo arranca y espera a que
      cargue el modelo (hasta ~25s). Reutiliza un server ya activo (p.ej. el
      que dejó corriendo otra reunión).
    - transcribe(wav): POST /inference (multipart) → texto.
    - close(): cierra sesión HTTP y mata el server SOLO si este objeto lo
      arrancó (un server ajeno se deja vivo).

    Configurable por env:
      AUDITOR_WHISPER_URL    (default http://127.0.0.1:8177)
      AUDITOR_WHISPER_BIN    (default ~/.local/share/whisper-cpp/bin/whisper-server)
      AUDITOR_WHISPER_MODEL  (default ~/.local/share/voxtype/models/ggml-large-v3-turbo.bin)
      AUDITOR_WHISPER_LANG   (default '' → auto-detección ES/EN por whisper)
    """

    def __init__(self, url: Optional[str] = None):
        self.url = (url or os.environ.get("AUDITOR_WHISPER_URL")
                    or "http://127.0.0.1:8177").rstrip("/")
        self.lang = os.environ.get("AUDITOR_WHISPER_LANG", "").strip()
        home = str(Path.home())
        self.bin = (os.environ.get("AUDITOR_WHISPER_BIN")
                    or f"{home}/.local/share/whisper-cpp/bin/whisper-server")
        self.model = (os.environ.get("AUDITOR_WHISPER_MODEL")
                      or f"{home}/.local/share/voxtype/models/ggml-large-v3-turbo.bin")
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._owned = False
        self._session: Optional[object] = None
        self._port = 8177
        try:
            self._port = int(self.url.rsplit(":", 1)[1].rstrip("/"))
        except Exception:
            pass

    async def _http(self):
        if self._session is None:
            import aiohttp
            self._session = aiohttp.ClientSession()
        return self._session

    async def health(self) -> bool:
        try:
            s = await self._http()
            async with s.get(f"{self.url}/health", timeout=3) as r:
                return r.status == 200
        except Exception:
            return False

    async def ensure(self) -> bool:
        """Garantiza un whisper-server respondiendo en self.url."""
        if await self.health():
            log.info(f"whisper-server ya activo en {self.url}")
            return True
        if not os.path.exists(self.bin):
            log.error(f"whisper-server no encontrado: {self.bin}")
            return False
        if not os.path.exists(self.model):
            log.error(f"modelo whisper no encontrado: {self.model}")
            return False
        log.info(f"Arrancando whisper-server (Vulkan): {self.bin}")
        libdir = os.path.join(os.path.dirname(self.bin), "..", "lib")
        env = os.environ.copy()
        prev = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = f"{libdir}:{prev}" if prev else libdir
        cmd = [self.bin, "-m", self.model, "--host", "127.0.0.1",
               "--port", str(self._port), "-t", "4", "--convert"]
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT, env=env)
            self._owned = True
        except Exception as e:
            log.error(f"fallo al arrancar whisper-server: {e}")
            return False
        # Esperar a que cargue el modelo (~2.7s) y responda /health
        for _ in range(80):  # 80 × 300ms = 24s máx
            if self._proc.returncode is not None:
                log.error("whisper-server murió al arrancar")
                return False
            if await self.health():
                log.info("whisper-server listo (modelo en VRAM)")
                return True
            await asyncio.sleep(0.3)
        log.error("whisper-server no respondió a /health a tiempo")
        return False

    async def transcribe(self, wav) -> str:
        """POST /inference → texto transcrito ('' si falla o no hay voz)."""
        import aiohttp

        wav = Path(wav)
        s = await self._http()
        try:
            form = aiohttp.FormData()
            form.add_field("file", open(wav, "rb"), filename=wav.name,
                           content_type="audio/wav")
            if self.lang:
                form.add_field("language", self.lang)
            async with s.post(f"{self.url}/inference", data=form,
                              timeout=30) as r:
                if r.status != 200:
                    log.warning(f"whisper-server HTTP {r.status}")
                    return ""
                data = await r.json()
        except Exception as e:
            log.warning(f"whisper-server transcribe error: {e}")
            return ""
        text = (data or {}).get("text", "") or ""
        return text.strip()

    async def close(self) -> None:
        if self._session is not None:
            try:
                await self._session.close()
            except Exception:
                pass
            self._session = None
        if self._owned and self._proc is not None:
            try:
                self._proc.terminate()
                await asyncio.wait_for(self._proc.wait(), timeout=3)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass
            self._owned = False
            self._proc = None


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

    p_capture = sub.add_parser("capture", help="Captura audio en vivo (mic+loopback) por fin-de-frase y transcribe con whisper-server (feed en vivo)")
    p_capture.add_argument("--mic-source", default=None, help="Source PipeWire del mic (default: source del sistema)")
    p_capture.add_argument("--loop-source", default=None, help="Monitor del sink (default: monitor del sink por defecto)")
    p_capture.add_argument("--vad-threshold", type=float, default=0.003)
    p_capture.add_argument("--min-silence-secs", type=float, default=0.8,
                           help="Silencio sostenido que cierra una frase (default 0.8s)")
    p_capture.add_argument("--max-phrase-secs", type=float, default=15.0,
                           help="Tope de duración por frase (default 15s)")
    p_capture.add_argument("--whisper-url", default=None,
                           help="URL del whisper-server (default env AUDITOR_WHISPER_URL o http://127.0.0.1:8177)")

    p_live = sub.add_parser("live", help="Modo reunión en vivo: lee transcript.json de voxtype (captions rápidos ~2-3s) + push-to-ask")
    p_live.add_argument("transcript", nargs="?", default=None,
                        help="Path opcional a un transcript.json concreto")
    p_live.add_argument("--poll", type=float, default=0.5)

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
    vault_search = os.environ.get("AUDITOR_VAULT_SEARCH", "true").lower() in ("true", "1", "yes")
    try:
        kb_threshold = float(os.environ.get("AUDITOR_KB_THRESHOLD", "0.70"))
    except ValueError:
        kb_threshold = 0.70
    auditor = MeetingAuditor(kb, None, {
        "min_score": args.min_score,
        "auto_reply": auto_reply,
        "vault_search": vault_search,
        "kb_threshold": kb_threshold,
    })

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
            await auditor.capture_live(mic_source=args.mic_source,
                                       loop_source=args.loop_source,
                                       vad_threshold=args.vad_threshold,
                                       min_silence_secs=args.min_silence_secs,
                                       max_phrase_secs=args.max_phrase_secs,
                                       whisper_url=args.whisper_url)
    elif args.cmd == "live":
        async with OmniRouteClient(ai_cfg) as ai:
            auditor.ai = ai
            await auditor.live_meeting(
                Path(args.transcript) if args.transcript else None,
                args.poll)
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