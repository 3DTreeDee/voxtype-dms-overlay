# Bugs y deuda técnica — Auditor de reuniones

> Actualizado: 2026-09-11 (sesión OpenCode, Sprint 1)
> Rama: `feat/auditor-meetings`
> Base: `docs/AUDITOR-PLAN.md` (fases 1-7) y `docs/HANDOFF-OPENGODE.md`
> Objetivo de este doc: lista viva de bugs abiertos + evidencia, para retomar
> el tema de transcripción en streaming (ver §3).

## 1. Resumen

| ID  | Sev   | Bug | Estado |
|-----|-------|-----|--------|
| B01 | Alta  | Primera frase perdida al iniciar reunión | Fix aplicado, validar |
| B02 | Alta  | Alucinación `"Gracias."` en silencio | Abierto (rollback tras prueba 2026-09-11) |
| B03 | Alta  | Anti-sidetone 7.9 (voz propia como "Remoto") | Fix aplicado, validar |
| B04 | Media | Frase corrupta al cierre (IME/teclado virtual) | Abierto |
| B05 | Media | Feed arrastra texto viejo / aparece en dictado | Mitigado, validar |
| B06 | Media | Latencia push-to-ask ~4-6 s (dominada por la IA) | Streaming implementado, validar en vivo |
| B07 | Baja  | Scroll invertido en la vista previa de Settings | Abierto |
| B08 | Baja  | `voxtype-export-mtg` vive fuera del repo | Abierto |
| B09 | Alta  | Ventana del auditor aparece/desaparece al iniciar reunión | **Resuelto** |
| B10 | Alta  | Contaminación de `config.toml` de voxtype (modelo `large`) | **Resuelto** |
| B11 | Media | Micro-saltos del feed mientras crece el stream | Abierto (documentado para próxima sesión) |

## 2. Detalle

### B01 — Primera frase perdida al iniciar reunión · Alta · Fix aplicado, validar
- **Síntoma**: la primera frase que dices tras pulsar "Iniciar reunión" no
  aparece en el feed.
- **Causa**: la señal de la reunión llegaba después del poll de estado, el
  respaldo y Python se arrancaban en serie, y `whisper.ensure()` bloqueaba la
  captura mientras el modelo cargaba en VRAM.
- **Fix aplicado**: el widget avisa de forma optimista al pulsar iniciar (con
  apagado automático si la reunión no se activa); el daemon arranca primero el
  auditor y en paralelo el respaldo de `voxtype meeting`; `capture_live`
  arranca `pw-record`/VAD mientras `whisper-server` carga en segundo plano.
- **Pendiente**: prueba en vivo hablando inmediatamente al pulsar iniciar.

### B02 — Alucinación `"Gracias."` en silencio · Alta · Abierto (rollback 2026-09-11)
- **Síntoma previo**: estando en silencio, el feed mostraba `"Gracias."`.
- **Evidencia previa** (sesión `run_id=436512`, `/tmp/voxtype-auditor/session_transcript.json`):
  | WAV | duración | RMS | transcripción |
  |---|---|---|---|
  | `phrase_436512_00011_1789098942723_mic.wav` | 0.30 s | **149** | "Gracias." |
  | `phrase_436512_00015_1789098992793_mic.wav` | 1.19 s | **128** | "Gracias." |
  Habla normal anterior = RMS 450-1200. Estos clips son ruido/silencio
  (RMS ≈ 0.004 en escala 0-1).
- **Causa raíz probable**:
  1. El VAD previo usa `vad_threshold = 0.003` y mínimo de frase 250 ms → el
     ruido de fondo puede cruzar el umbral y generar "frases" vacías.
  2. `whisper-server` se arranca sin filtros anti-alucinación; con audio casi
     mudo Whisper puede alucinar `"Gracias."` (patrón típico en español).
- **Intento revertido**: umbral `0.012`, voz mínima `0.3 s`, frase mínima
  `0.5 s`, servidor con `--suppress-nst`/`--no-speech-thold 0.8`, y filtro
  exacto de alucinaciones cortas y débiles.
- **Por qué se revirtió**: en la prueba en vivo del 2026-09-11, con el umbral
  alto se perdieron frases reales del micrófono (voz de baja energía), el
  push-to-ask dejó de recibir voz y el `"Gracias."` final correspondía a un
  fragmento audible de 1.11 s, no a silencio. El rollback devuelve el VAD
  previo y deja este ajuste como fine-tuning final.
- **Pendiente**: calibración adaptativa por energía del micrófono, sin romper
  la detección de voz baja.

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

### B06 — Latencia push-to-ask ~4-6 s · Media · Streaming implementado, validar en vivo
- **Desglose previo**: cierre VAD ~0.8 s + whisper ~0.5 s + sleep 0.5 s + IA
  `auto/best-chat` ~3.5 s. Dominada por la llamada a la IA.
- **Fix aplicado**: `chat_completion_stream` SSE robusto, eventos
  `ai_stream_start/delta/done/error` correlacionados por `request_id`,
  render progresivo solo en “Sugerir”, fallback sincrónico sin tokens y error
  parcial marcado como incompleto si el stream se interrumpe.
- **Pendiente**: medir primer token en reunión real y confirmar latencia
  percibida ≤~2 s. Los micro-saltos residuales del render se siguen en B11; el
  retardo del primer token es del proveedor, no del render.

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

### B11 — Micro-saltos del feed durante el stream · Media · Abierto (documentado para próxima sesión)
- **Síntoma**: con auto-scroll ON, la respuesta progresiva aparece pero la vista
  hace pequeños saltos mientras el texto crece.
- **Evidencia** (sesión `session_20260911-062845_1390506.jsonl`, proveedor
  `auto/best-chat`):
  | request | primer token | deltas | total |
  |---|---:|---:|---:|
  | `mtwvifem-fv66` | 10 745.1 ms | 1 / 97 caracteres | 12 259.3 ms |
  | `mtwvj979-7moy` | 19 546.3 ms | 42 / 363 caracteres | 23 091.5 ms |
  | `mtwvk5n9-q9x0` | 18 159.6 ms | 99 / 830 caracteres | 23 757.0 ms |
- **Mitigaciones ya aplicadas**:
  - Lotes en Python: primer delta inmediato, luego cada 75 ms o 64 caracteres.
  - QML conserva un solo placeholder por `request_id`; los deltas actualizan
    `streamTexts` + `streamRevision` sin reconstruir todo el modelo.
  - Auto-scroll con una sola llamada diferida y animación de 120 ms solo cuando
    auto-scroll está ON.
- **Hipótesis abiertas**:
  1. `contentHeight` cambia por reflow mientras la animación y las llamadas a
     `positionViewAtEnd` compiten entre lotes.
  2. Otros captions/debug intercalados o el recorte `maxEvents` mueven el
     modelo durante el stream.
  3. Re-medición del delegate por wrap, emoji, fuentes o altura del cursor.
- **Próxima sesión**:
  1. Instrumentar `contentY`, `contentHeight`, `count` y timestamps durante un
     stream con debug.
  2. Comparar auto-scroll ON/OFF y respuestas cortas/largas.
  3. Evaluar anclaje de cola con actualización coalescida por frame o un modelo
     dedicado a la fila activa.
  4. No cambiar de modelo/proveedor en ese paso: el retardo del primer token es
     un problema separado del render.

## 3. Tema abierto: ¿transcripción en streaming?

Estado actual: **sin streaming**. ASR = `whisper-server` HTTP que transcribe un
WAV completo por frase (VAD), sin parciales. IA = `chat_completion` no-streaming.
Ver `docs/AUDITOR-PLAN.md` §Fase 6 (se descartó parakeet/nemotron streaming) y
análisis en la conversación de la sesión 2026-09-10.
