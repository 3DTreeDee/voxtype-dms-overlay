# Bugs y deuda técnica — Auditor de reuniones

> Actualizado: 2026-09-10 (sesión OpenCode)
> Rama: `feat/auditor-meetings`
> Base: `docs/AUDITOR-PLAN.md` (fases 1-7) y `docs/HANDOFF-OPENGODE.md`
> Objetivo de este doc: lista viva de bugs abiertos + evidencia, para retomar
> el tema de transcripción en streaming (ver §3).

## 1. Resumen

| ID  | Sev   | Bug | Estado |
|-----|-------|-----|--------|
| B01 | Alta  | Primera frase perdida al iniciar reunión | Abierto |
| B02 | Alta  | Alucinación `"Gracias."` en silencio | **Abierto (nuevo)** |
| B03 | Alta  | Anti-sidetone 7.9 (voz propia como "Remoto") | Fix aplicado, validar |
| B04 | Media | Frase corrupta al cierre (IME/teclado virtual) | Abierto |
| B05 | Media | Feed arrastra texto viejo / aparece en dictado | Mitigado, validar |
| B06 | Media | Latencia push-to-ask ~4-6 s (dominada por la IA) | Mejora |
| B07 | Baja  | Scroll invertido en la vista previa de Settings | Abierto |
| B08 | Baja  | `voxtype-export-mtg` vive fuera del repo | Abierto |
| B09 | Alta  | Ventana del auditor aparece/desaparece al iniciar reunión | **Resuelto** |
| B10 | Alta  | Contaminación de `config.toml` de voxtype (modelo `large`) | **Resuelto** |

## 2. Detalle

### B01 — Primera frase perdida al iniciar reunión · Alta · Abierto
- **Síntoma**: la primera frase que dices tras pulsar "Iniciar reunión" no
  aparece en el feed.
- **Causa**: `OverlayDaemon.startAuditor()` espera ~2 s (`Qt.callLater` doble,
  `OverlayDaemon.qml:377`) antes de lanzar `auditor.py capture`; los `pw-record`
  aún no graban.
- **Fix propuesto**: pre-arrancar `LiveCapture` en idle al abrir el panel, o
  esperar a que los `pw-record` estén activos antes de confirmar el inicio.

### B02 — Alucinación `"Gracias."` en silencio · Alta · Abierto (NUEVO)
- **Síntoma**: estando en silencio, el feed muestra `"Gracias."`.
- **Evidencia** (sesión `run_id=436512`, `/tmp/voxtype-auditor/session_transcript.json`):
  | WAV | duración | RMS | transcripción |
  |---|---|---|---|
  | `phrase_436512_00011_1789098942723_mic.wav` | 0.30 s | **149** | "Gracias." |
  | `phrase_436512_00015_1789098992793_mic.wav` | 1.19 s | **128** | "Gracias." |
  Habla normal = RMS 450-1200. Estos clips son ruido/silencio (RMS ≈ 0.004 en
  escala 0-1).
- **Causa raíz**:
  1. `audio_capture.py` usa `vad_threshold = 0.003` (`audio_capture.py:217`) y
     mínimo de frase 250 ms (`audio_capture.py:508`) → el ruido de fondo cruza
     el umbral y genera "frases" vacías.
  2. `whisper-server` se arranca sin filtros anti-alucinación
     (`auditor.py:1096`); con audio casi mudo Whisper alucina `"Gracias."`
     (patrón típico en español).
- **Fix propuesto** (de menor a mayor esfuerzo):
  1. Subir `vad_threshold` a ~0.010-0.015 y/o exigir mínimo de energía sostenida
     y mínimo de frase mayor (~500 ms).
  2. Arrancar `whisper-server` con `-sns` (`--suppress-nst`) y `-nth 0.8`
     (`--no-speech-thold`); ambos existen en el binario instalado.
  3. Filtro post-transcripción: descartar si RMS del clip es bajo **y** el texto
     está en una lista de alucinaciones conocidas ("Gracias.", "Thank you.",
     "Subtítulos realizados por…").
  4. (Opcional) `--vad` con Silero (`ggml-silero-v5.1.2.bin`, no instalado).

### B03 — Anti-sidetone 7.9 (voz propia sale como "Remoto") · Alta · Validar
- **Fix aplicado**: regla temporal en `audio_capture.py` — si el loop cierra
  frase con el mic hablando hace <2 s, se descarta (sidetone HFP/BT). Ver
  `docs/AUDITOR-PLAN.md` §7.9.
- **Pendiente**: prueba en vivo con BT puesto y sonido por el sink.

### B04 — Frase corrupta al cierre · Media · Abierto
- **Síntoma**: última frase ("Toðallos mírs…") con caracteres islandeses.
- **Hipótesis**: frase cortada por el cierre + IME/teclado virtual del widget.
- **Fix propuesto**: verificar si cerrar el teclado virtual al terminar la
  reunión lo elimina; si es del overlay, corregir en `OverlayWindow.qml`.

### B05 — Feed arrastra texto viejo / aparece en dictado · Media · Mitigado
- **Síntoma**: al abrir reunión nueva el feed mostraba captions previos; y el
  panel aparecía durante el dictado normal.
- **Causa**: `events` no se limpiaba al parar, y `auditorMeetingActive` podía
  quedar pegado en `true` (reunión interrumpida).
- **Fix aplicado**: `AuditorThread.stop()` limpia `events`; `OverlayDaemon`
  reconcilia `meetingRunning` contra `voxtype meeting status` al cargar.
- **Pendiente**: validar en vivo.

### B06 — Latencia push-to-ask ~4-6 s · Media · Mejora
- **Desglose** (`auditor.py:572`): cierre VAD ~0.8 s + whisper ~0.5 s + sleep
  0.5 s + IA `auto/best-chat` ~3.5 s. Dominada por la llamada a la IA.
- **Mejora**: implementar `chat_completion_stream` (`omniroute_client.py:167`
  es `NotImplementedError`) y renderizar tokens progresivos.

### B07 — Scroll invertido en Settings · Baja · Abierto
- Solo en la vista previa de `Settings.qml`; el feed real ya funciona.

### B08 — `voxtype-export-mtg` fuera del repo · Baja · Abierto
- Vive en `~/.local/bin/voxtype-export-mtg`; moverlo a `scripts/` e instalarlo
  desde el daemon.

### B09 — Ventana aparece/desaparece al iniciar reunión · Alta · RESUELTO
- **Causa**: `startAuditor()` hacía swap de modelo (`whisper.model` →
  `large-v3-turbo`) que ejecuta `systemctl restart voxtype`, matando la reunión
  recién arrancada; el widget veía "sin reunión" y el daemon revertía → otro
  restart. Evidencia: 4 reinicios de `voxtype` entre 22:29-22:30 y escritura de
  `config.toml` a las 22:30:04.
- **Fix**: eliminadas las llamadas al swap en el ciclo de reunión. Las captions
  en vivo usan el `whisper-server` propio (large-v3-turbo), independiente del
  `whisper.model` de voxtype.

### B10 — Contaminación de `config.toml` · Alta · RESUELTO
- **Causa**: `voxtype-model-swap.sh` nunca revertía por 3 bugs (`local` fuera de
  función con `set -e`, doble codificación del state, modelos `$2/$3`
  ignorados), así que el modelo quedaba en `large-v3-turbo` (1.7 GB) para
  dictado normal.
- **Fix**: script corregido y round-trip verificado; `config.toml` restaurado a
  `small` (igual que el `.bak` original). Swap desactivado por defecto.

## 3. Tema abierto: ¿transcripción en streaming?

Estado actual: **sin streaming**. ASR = `whisper-server` HTTP que transcribe un
WAV completo por frase (VAD), sin parciales. IA = `chat_completion` no-streaming.
Ver `docs/AUDITOR-PLAN.md` §Fase 6 (se descartó parakeet/nemotron streaming) y
análisis en la conversación de la sesión 2026-09-10.
