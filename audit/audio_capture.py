"""audio_capture.py — Captura de audio en vivo para el Auditor de Reuniones.

Captura continua con corte por FIN-DE-FRASE (VAD), Fase 6:

- Un pw-record CONTINUO por lado (micrófono → You, loopback → Remote) escribe
  un WAV de sesión que crece sin cortes → cero solape perdido entre chunks
  (el diseño viejo de chunks de duración fija perdía ~50ms de arranque de
  pw-record entre chunk y chunk).
- Un lector por lado muestrea su WAV de sesión cada poll_secs (~100ms), mide
  el RMS por ventana y detecta VOZ seguida de SILENCIO sostenido
  (min_silence_secs, ~0.8s) → cierra la frase: recorta los frames de voz a un
  WAV de frase y lo encola (AudioChunk). Frases de ≥ max_phrase_secs (~15s)
  se cortan por timeout para no perder audio largo.
- Latencia percibida del caption ≈ fin de la frase + inferencia del modelo
  (en vez de "chunk fijo de N segundos").
- Si mic y loopback capturan audio byte-idéntico (sink SUSPENDED → pw-record
  resuelve al source por defecto), el duplicado se descarta comparando hash
  de la frase recién cerrada entre lados.

La transcripción NO ocurre aquí: el consumidor recibe AudioChunk con WAVs de
frase listos para enviar al motor (whisper-server HTTP / voxtype transcribe).
"""

from __future__ import annotations

import asyncio
import hashlib
import math
import os
import shutil
import subprocess
import tempfile
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional, Tuple

SAMPLE_RATE = 16000
_CHANNELS = 1
_SAMPWIDTH = 2  # s16


def _default_mic_source() -> Optional[str]:
    """Source de PipeWire por defecto (el mismo que usa voxtype con device=default)."""
    try:
        out = subprocess.run(
            ["pactl", "get-default-source"], capture_output=True, text=True, timeout=5
        ).stdout.strip()
        return out or None
    except Exception:
        return None


def _default_loopback_source() -> Optional[str]:
    """Monitor del sink por defecto — captura el audio que sale a los altavoces
    (remotos en Meet/Zoom/Teams).

    OJO: si el sink por defecto está SUSPENDED (nada sonando), pw-record
    --target de su monitor resuelve silenciosamente al source por defecto
    (¡el mic!) y graba audio duplicado byte-idéntico. La detección de eso se
    hace al cerrar frase (hash entre lados).
    """
    try:
        out = subprocess.run(
            ["pactl", "list", "sinks", "short"], capture_output=True, text=True, timeout=5
        ).stdout
        sinks = []
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 5:
                sinks.append((parts[0].strip(), parts[1].strip(), parts[4].strip()))
        if not sinks:
            return None
        try:
            default = subprocess.run(
                ["pactl", "get-default-sink"], capture_output=True, text=True, timeout=5
            ).stdout.strip()
        except Exception:
            default = ""
        for sid, name, state in sinks:
            if name == default and state in ("RUNNING", "IDLE"):
                return name + ".monitor"
        for sid, name, state in sinks:
            if state in ("RUNNING", "IDLE") and "auto_null" not in name and "silence" not in name:
                return name + ".monitor"
        return None
    except Exception:
        return None


def _files_identical(a: Path, b: Path) -> bool:
    """True si dos WAVs son byte-idénticos (loopback duplicado del mic)."""
    try:
        if not a.exists() or not b.exists():
            return False
        if a.stat().st_size != b.stat().st_size:
            return False
        h = hashlib.sha256()
        with open(a, "rb") as fa, open(b, "rb") as fb:
            while True:
                ca, cb = fa.read(1 << 16), fb.read(1 << 16)
                if ca != cb:
                    return False
                if not ca:
                    break
        return True
    except Exception:
        return False


def _rms_level(wav_path: Path) -> float:
    """Nivel RMS (0..1) de un WAV s16 mono. < 0.003 ~ silencio."""
    try:
        with wave.open(str(wav_path), "rb") as w:
            if w.getsampwidth() != 2:
                return 1.0  # no s16: no juzgar
            n = w.getnframes()
            if n == 0:
                return 0.0
            frames = w.readframes(min(n, SAMPLE_RATE * 8))  # máx 8s
        import array

        samples = array.array("h")
        samples.frombytes(frames)
        if len(samples) == 0:
            return 0.0
        acc = 0.0
        for s in samples:
            acc += (s / 32768.0) ** 2
        return math.sqrt(acc / len(samples))
    except Exception:
        return 0.0


@dataclass
class AudioChunk:
    """Una frase capturada: WAV del mic y/o del loopback con voz."""

    mic_wav: Optional[Path] = None
    loop_wav: Optional[Path] = None
    mic_rms: float = 0.0
    loop_rms: float = 0.0


def _wav_data_offset(path: Path) -> int:
    """Offset del payload PCM dentro del WAV (busca el chunk 'data').

    pw-record escribe el header al abrir y NO lo actualiza mientras graba
    (el data size del header queda en 0x7fffffff hasta el cierre), así que
    leer "hasta EOF" es la única forma fiable de leer en vivo. El offset del
    data se detecta en runtime por si el header no es el PCM estándar de 44.
    """
    try:
        with open(path, "rb") as f:
            head = f.read(512)
        idx = head.find(b"data")
        if idx >= 0:
            return idx + 8
    except Exception:
        pass
    return 44  # WAV PCM estándar


def _write_phrase_wav(path: Path, frames: bytes) -> None:
    """Escribe un WAV PCM s16 mono 16kHz a partir de frames crudos."""
    import struct

    data_size = len(frames)
    hdr = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + data_size, b"WAVE",
        b"fmt ", 16, 1, _CHANNELS, SAMPLE_RATE,
        SAMPLE_RATE * _CHANNELS * _SAMPWIDTH, _CHANNELS * _SAMPWIDTH, 16,
        b"data", data_size,
    )
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(frames)


def _rms_bytes(chunk: bytes) -> float:
    """RMS (0..1) de un bloque de samples s16 LE crudos."""
    import array

    if len(chunk) < 2:
        return 0.0
    samples = array.array("h")
    samples.frombytes(chunk)
    acc = 0.0
    for s in samples:
        acc += (s / 32768.0) ** 2
    return math.sqrt(acc / len(samples))


@dataclass
class _SideState:
    """Estado de detección de frase para un lado (mic o loopback)."""

    in_speech: bool = False
    silence_secs: float = 0.0
    speech_secs: float = 0.0
    wins: List[Tuple[float, bytes]] = field(default_factory=list)


class LiveCapture:
    """Captura continua por lado + corte por fin-de-frase (VAD).

    API: start() → next_chunk() (AudioChunk por frase) → stop().
    """

    def __init__(
        self,
        mic_source: Optional[str] = None,
        loop_source: Optional[str] = None,
        vad_threshold: float = 0.003,
        min_silence_secs: float = 0.8,
        max_phrase_secs: float = 15.0,
        poll_secs: float = 0.1,
        tmp_dir: Optional[Path] = None,
    ):
        self.mic_source = mic_source or _default_mic_source()
        self.loop_source = loop_source or _default_loopback_source()
        self.vad_threshold = vad_threshold
        self.min_silence_secs = min_silence_secs
        self.max_phrase_secs = max_phrase_secs
        self.poll_secs = poll_secs
        self.tmp_dir = Path(tmp_dir or tempfile.gettempdir()) / "voxtype-auditor"
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        self._chunks: asyncio.Queue[Optional[AudioChunk]] = asyncio.Queue()
        self._running = False
        self._rec_task: Optional[asyncio.Task] = None
        self._watch_tasks: List[asyncio.Task] = []
        self._procs: List[asyncio.subprocess.Process] = []
        self._session_wavs: List[Path] = []
        self._seq = 0
        # Última frase cerrada por lado (para dedupe byte-idéntico mic/loop)
        self._last_closed: dict = {"tag": None, "digest": None, "at": 0.0}

    # -- API --
    async def start(self) -> None:
        """Arranca pw-record continuo por lado + lectores de fin-de-frase."""
        if self._running:
            return
        self._running = True
        self._rec_task = asyncio.create_task(self._record_loop())
        # info a stdout (JSONL igual que el resto del auditor)
        print(
            __import__("json").dumps(
                {
                    "type": "info",
                    "msg": (f"captura por frase: mic={self.mic_source} "
                            f"loop={self.loop_source} silencio≥{self.min_silence_secs}s "
                            f"tope={self.max_phrase_secs}s"),
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    async def stop(self) -> None:
        self._running = False
        # Cerrar frases pendientes antes de matar la captura
        for task in list(self._watch_tasks):
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self._watch_tasks = []
        for p in self._procs:
            try:
                p.terminate()
                await asyncio.wait_for(p.wait(), timeout=2)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
        self._procs = []
        if self._rec_task:
            self._rec_task.cancel()
            try:
                await self._rec_task
            except (asyncio.CancelledError, Exception):
                pass
            self._rec_task = None

    async def next_chunk(self) -> Optional[AudioChunk]:
        return await self._chunks.get()

    # -- Interno --
    async def _record_loop(self) -> None:
        """Lanza un pw-record continuo por lado y un lector por lado."""
        sample_rate = SAMPLE_RATE
        self._seq += 1
        seq = self._seq

        sides = []
        if self.mic_source:
            sides.append(("mic", self.mic_source))
        if self.loop_source:
            sides.append(("loop", self.loop_source))
        if not sides:
            print(__import__("json").dumps({"type": "info",
                  "msg": "captura sin fuentes: mic y loopback no disponibles"}),
                  flush=True)
            await self._chunks.put(None)
            return

        for tag, src in sides:
            wav = self.tmp_dir / f"session_{seq:05d}_{tag}.wav"
            self._session_wavs.append(wav)
            try:
                proc = await self._pw_record_start(src, wav, sample_rate)
                if proc:
                    self._procs.append(proc)
            except Exception as e:
                print(__import__("json").dumps({"type": "info",
                      "msg": f"fallo pw-record {tag}: {e}"}), flush=True)

        if not self._procs:
            await self._chunks.put(None)
            return

        # Un lector por lado; ambos encolan en self._chunks
        for tag, src in sides:
            wav = self.tmp_dir / f"session_{seq:05d}_{tag}.wav"
            self._watch_tasks.append(
                asyncio.create_task(self._watch_side(tag, wav)))

        # Si todos los pw-record mueren, terminar la captura
        try:
            while self._running:
                alive = [p for p in self._procs if p.returncode is None]
                if not alive:
                    print(__import__("json").dumps({"type": "info",
                          "msg": "pw-record terminó — fin de captura"}), flush=True)
                    await self._chunks.put(None)
                    break
                await asyncio.sleep(2)
        except asyncio.CancelledError:
            raise

    async def _pw_record_start(self, source: str, out: Path, rate: int
                               ) -> Optional[asyncio.subprocess.Process]:
        """pw-record CONTINUO (sin --sample-count): graba hasta que lo matemos."""
        pw = shutil.which("pw-record")
        if not pw:
            return None
        cmd = [pw, "--target", source, "--rate", str(rate),
               "--channels", "1", "--format", "s16",
               "--latency", "50ms", str(out)]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            return proc
        except Exception:
            return None

    async def _watch_side(self, tag: str, wav_path: Path) -> None:
        """Lee el WAV de sesión mientras crece y cierra frases por VAD."""
        state = _SideState()
        data_start = 0
        read_pos = 0
        while self._running:
            try:
                if not wav_path.exists():
                    await asyncio.sleep(self.poll_secs)
                    continue
                if data_start == 0:
                    data_start = _wav_data_offset(wav_path)
                    read_pos = data_start
                try:
                    size = wav_path.stat().st_size
                except OSError:
                    await asyncio.sleep(self.poll_secs)
                    continue
                if size <= read_pos:
                    await asyncio.sleep(self.poll_secs)
                    continue
                with open(wav_path, "rb") as f:
                    f.seek(read_pos)
                    chunk = f.read(size - read_pos)
                # Si pw-record está a mitad de escritura puede sobrar 1 byte impar
                if len(chunk) % 2:
                    chunk = chunk[:-1]
                read_pos = size
                if not chunk:
                    await asyncio.sleep(self.poll_secs)
                    continue
                self._feed_side(tag, state, chunk)
            except asyncio.CancelledError:
                raise
            except Exception:
                await asyncio.sleep(self.poll_secs)
        # Cerrar la frase pendiente al terminar (si hay voz a medias)
        try:
            self._close_side(tag, state, force=True)
        except Exception:
            pass

    def _feed_side(self, tag: str, state: _SideState, chunk: bytes) -> None:
        secs = len(chunk) / (SAMPLE_RATE * _SAMPWIDTH)
        rms = _rms_bytes(chunk)
        if rms > self.vad_threshold:
            if not state.in_speech:
                state.in_speech = True
                state.silence_secs = 0.0
                state.speech_secs = 0.0
                state.wins = []
            state.wins.append((rms, chunk))
            state.silence_secs = 0.0
            state.speech_secs += secs
            if state.speech_secs >= self.max_phrase_secs:
                self._close_side(tag, state, force=True)  # corte por timeout
        else:
            if state.in_speech:
                state.wins.append((rms, chunk))
                state.silence_secs += secs
                if state.silence_secs >= self.min_silence_secs:
                    self._close_side(tag, state)

    def _close_side(self, tag: str, state: _SideState, force: bool = False) -> None:
        """Cierra la frase actual: recorta los frames de voz y encola el chunk."""
        if not state.in_speech:
            return
        state.in_speech = False
        wins = state.wins
        state.wins = []
        if not wins:
            return

        if not force:
            # Quitar el silencio final: conservar hasta la última ventana con
            # voz + 2 de cola (~200ms) para no cortar consonantes finales.
            last_voice = -1
            for i, (r, _) in enumerate(wins):
                if r > self.vad_threshold:
                    last_voice = i
            if last_voice < 0:
                return
            end = min(len(wins), last_voice + 2)
        else:
            end = len(wins)

        frames = b"".join(b for _, b in wins[:end])
        if len(frames) < SAMPLE_RATE * _SAMPWIDTH * 0.25:
            return  # menos de 250ms de voz: no es frase

        peak = max((r for r, _ in wins[:end]), default=0.0)

        # Dedupe: si el otro lado cerró una frase byte-idéntica hace <1s
        # (sink SUSPENDED → loopback grabó el mic), descartar el duplicado.
        now = time.time()
        digest = hashlib.sha256(frames).hexdigest()
        other = "loop" if tag == "mic" else "mic"
        if (self._last_closed["tag"] == other
                and self._last_closed["digest"] == digest
                and now - self._last_closed["at"] < 1.5):
            self._last_closed.update(tag=tag, digest=digest, at=now)
            return
        self._last_closed.update(tag=tag, digest=digest, at=now)

        self._seq += 1
        ts = int(now * 1000)
        out = self.tmp_dir / f"phrase_{self._seq:05d}_{ts}_{tag}.wav"
        try:
            _write_phrase_wav(out, frames)
        except Exception:
            return
        if tag == "mic":
            self._chunks.put_nowait(AudioChunk(mic_wav=out, mic_rms=peak))
        else:
            self._chunks.put_nowait(AudioChunk(loop_wav=out, loop_rms=peak))

    @property
    def mic_source_name(self) -> str:
        return self.mic_source or ""
