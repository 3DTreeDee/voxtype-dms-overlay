"""audio_capture.py — Captura de audio en vivo para el Auditor de Reuniones.

Graba chunks del micrófono y del loopback del sistema (remotos) con pw-record,
detecta si hay voz (RMS), y entrega WAVs de 16kHz mono listos para transcribir
con `voxtype transcribe` (modelo residente en el daemon → inferencia barata).

Diseño:
  - chunk_secs: duración de cada chunk (default 6.0). Latencia del feed ≈
    chunk_secs + tiempo de transcripción del modelo.
  - Los chunks se graban SECUENCIALMENTE: mientras se transcribe el chunk N,
    se sigue grabando el chunk N+1 (grabación en hilo separado). Así el feed
    no pierde audio durante la inferencia.
"""

from __future__ import annotations

import asyncio
import math
import os
import shutil
import subprocess
import tempfile
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


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
    (¡el mic!) y graba audio duplicado byte-idéntico. Por eso preferimos un
    sink ACTIVO (RUNNING/IDLE); si todos están SUSPENDED devolvemos None y el
    capture graba solo el mic (el loopback no tiene nada que capturar).
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
        # Preferir el sink por defecto si está activo
        try:
            default = subprocess.run(
                ["pactl", "get-default-sink"], capture_output=True, text=True, timeout=5
            ).stdout.strip()
        except Exception:
            default = ""
        for sid, name, state in sinks:
            if name == default and state in ("RUNNING", "IDLE"):
                return name + ".monitor"
        # Si no, el primer sink activo distinto de "auto_null"/"silence"
        for sid, name, state in sinks:
            if state in ("RUNNING", "IDLE") and "auto_null" not in name and "silence" not in name:
                return name + ".monitor"
        return None
    except Exception:
        return None


def _files_identical(a: Path, b: Path) -> bool:
    """True si dos WAVs son byte-idénticos (loopback duplicado del mic)."""
    import hashlib
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
            frames = w.readframes(min(n, 16000 * 8))  # máx 8s
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
    """Un chunk capturado: mic y/o loopback con voz."""

    mic_wav: Optional[Path] = None
    loop_wav: Optional[Path] = None
    mic_rms: float = 0.0
    loop_rms: float = 0.0


class LiveCapture:
    """Captura continua: graba chunks de `chunk_secs` y los entrega por cola."""

    def __init__(
        self,
        chunk_secs: float = 6.0,
        mic_source: Optional[str] = None,
        loop_source: Optional[str] = None,
        vad_threshold: float = 0.003,
        tmp_dir: Optional[Path] = None,
    ):
        self.chunk_secs = chunk_secs
        self.mic_source = mic_source or _default_mic_source()
        self.loop_source = loop_source or _default_loopback_source()
        self.vad_threshold = vad_threshold
        self.tmp_dir = Path(tmp_dir or tempfile.gettempdir()) / "voxtype-auditor"
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        self._chunks: asyncio.Queue[Optional[AudioChunk]] = asyncio.Queue()
        self._running = False
        self._rec_task: Optional[asyncio.Task] = None
        self._seq = 0
        self._cleanup_task: Optional[asyncio.Task] = None

    # -- API --
    async def start(self) -> None:
        """Arranca la grabación en background. Los chunks llegan por `next_chunk()`."""
        if self._running:
            return
        self._running = True
        self._rec_task = asyncio.create_task(self._record_loop())
        self._cleanup_task = asyncio.create_task(self._cleanup_loop())
        # info a stdout
        print(
            __import__("json").dumps(
                {
                    "type": "info",
                    "msg": f"captura en vivo: mic={self.mic_source} loop={self.loop_source} chunk={self.chunk_secs}s",
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    async def stop(self) -> None:
        self._running = False
        for task in (self._rec_task, self._cleanup_task):
            if task:
                task.cancel()
                try:
                    await task
                except (asyncio.CancelledError, Exception):
                    pass
        self._rec_task = None
        self._cleanup_task = None

    async def _cleanup_loop(self) -> None:
        """Borra WAVs de chunks ya transcritos (los N-2 más recientes se
        conservan por si el transcriptor aún los lee)."""
        import glob
        try:
            while self._running:
                await asyncio.sleep(30)
                wavs = sorted(glob.glob(str(self.tmp_dir / "chunk_*_*.wav")))
                for f in wavs[:-6]:  # conserva los 3 chunks más recientes
                    try:
                        Path(f).unlink(missing_ok=True)
                    except Exception:
                        pass
        except asyncio.CancelledError:
            raise
        except Exception:
            pass

    async def next_chunk(self) -> Optional[AudioChunk]:
        return await self._chunks.get()

    # -- Interno --
    async def _record_loop(self) -> None:
        while self._running:
            try:
                chunk = await asyncio.wait_for(
                    self._record_one_chunk(), timeout=self.chunk_secs + 15
                )
                if chunk and (chunk.mic_rms > self.vad_threshold or chunk.loop_rms > self.vad_threshold):
                    await self._chunks.put(chunk)
            except asyncio.CancelledError:
                raise
            except Exception:
                # no matar el loop por un chunk fallido
                await asyncio.sleep(0.5)

    async def _record_one_chunk(self) -> Optional[AudioChunk]:
        """Graba mic y loopback en paralelo durante chunk_secs.

        Usa nombres de archivo ÚNICOS por chunk (secuencia) porque el
        consumidor transcribe el chunk N mientras este método ya graba el
        N+1: con nombres fijos, el grabador borraría/reescribiría el archivo
        que el transcriptor aún está leyendo → transcripción vacía. La
        limpieza de archivos viejos corre aparte (ver _cleanup_old).
        """
        sample_rate = 16000
        n_samples = int(sample_rate * self.chunk_secs)
        self._seq += 1
        seq = self._seq

        mic_wav = self.tmp_dir / f"chunk_{seq:05d}_mic.wav"
        loop_wav = self.tmp_dir / f"chunk_{seq:05d}_loop.wav"

        procs = []
        if self.mic_source:
            procs.append(("mic", self.mic_source, mic_wav))
        if self.loop_source:
            procs.append(("loop", self.loop_source, loop_wav))

        if not procs:
            return None

        tasks = []
        for tag, source, out in procs:
            tasks.append(
                asyncio.create_task(
                    self._pw_record(source, out, sample_rate, n_samples)
                )
            )
        results = await asyncio.gather(*tasks, return_exceptions=True)

        mic_rms = loop_rms = 0.0
        mic_path = loop_path = None
        for (tag, _, out), res in zip(procs, results):
            if isinstance(res, Exception) or not out.exists() or out.stat().st_size < 2000:
                continue
            rms = _rms_level(out)
            if tag == "mic":
                mic_rms = rms
                mic_path = out if rms > self.vad_threshold else None
            else:
                loop_rms = rms
                loop_path = out if rms > self.vad_threshold else None
        # Si el loopback es byte-idéntico al mic, el sink estaba SUSPENDED y
        # pw-record resolvió al source por defecto: descartar el "remoto" falso.
        if (mic_path and loop_path and mic_rms > self.vad_threshold
                and _files_identical(mic_path, loop_path)):
            loop_path = None
            loop_rms = 0.0
        return AudioChunk(mic_wav=mic_path, loop_wav=loop_path, mic_rms=mic_rms, loop_rms=loop_rms)

    async def _pw_record(self, source: str, out: Path, rate: int, n_samples: int) -> None:
        """pw-record con detención por --sample-count (más fiable que kill)."""
        pw = shutil.which("pw-record")
        if not pw:
            raise RuntimeError("pw-record no está instalado")
        cmd = [
            pw,
            "--target", source,
            "--rate", str(rate),
            "--channels", "1",
            "--format", "s16",
            "--sample-count", str(n_samples),
            "--latency", "100ms",
            str(out),
        ]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        # pw-record no soporta --sample-count? (PipeWire <0.3.70 no lo tiene).
        # Si sale al instante con error, reintentar con kill por tiempo.
        try:
            await asyncio.wait_for(proc.wait(), timeout=self.chunk_secs + 3)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
        if proc.returncode not in (0, -9, None):
            # Puede que --sample-count no existiera: reintentar sin él
            if not out.exists() or out.stat().st_size < 2000:
                cmd = [
                    pw,
                    "--target", source,
                    "--rate", str(rate),
                    "--channels", "1",
                    "--format", "s16",
                    "--latency", "100ms",
                    str(out),
                ]
                proc2 = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                try:
                    await asyncio.wait_for(proc2.wait(), timeout=self.chunk_secs + 1)
                except asyncio.TimeoutError:
                    proc2.kill()
                    await proc2.wait()
