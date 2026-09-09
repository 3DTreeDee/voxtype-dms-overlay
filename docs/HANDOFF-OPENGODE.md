# Handoff: Auditor de Reuniones — Documentación para OpenCode

> Documentado: 2026-09-09 (~04:40 local)
> Repo: `~/Proyectos/GitHub/voxtype-dms-overlay`, rama `feat/auditor-meetings`
> Plugin: `~/.config/DankMaterialShell/plugins/voxtypeOverlay/`
> Skill: `dms-voxtype-plugins` cargada en Hermes

## Estado actual

### ✅ Funciona
- **whisper-server 8177** (Vulkan, large-v3-turbo) — transcribe multipart en ~0.6s/request
- **Selector de fuentes desde el widget** (Settings > Plugins > VoxType Recording Overlay): mic y loop fijos, con "Refrescar dispositivos"
- **El mic BT se filtró** del dropdown de micrófono (solo webcam/USB + System default)
- **Prioridad temporal del mic** en `audio_capture.py`: si el mic detecta voz, el loop no se transcribe (sidetone HFP) — ver rediseño 7.9
- **Dedupe textual secundario** en `auditor.py` (ventana 12s): si el "Tú" dijo el texto antes que "Remoto", el remoto se descarta
- **Idioma español** (`language=es` en whisper-server)
- **Fix backlog del lector**: lectura limitada a ~0.4s/iteración (antes leía todo el backlog → frases de 109s de golpe)
- **Fix hora local en exportaciones**: `voxtype-export-mtg` reescribe UTC → hora local (-05)

### ❌ No funciona (causa raíz encontrada)
**Problema principal**: `pw-record --target bluez_output.84_AC_60_12_A9_31.1.monitor` NO captura el monitor — PipeWire lo re-rutea a la webcam (Source 52) incluso con el monitor en estado RUNNING.
- **Evidencia**: 3 pw-record independientes apuntando al monitor BT, todos conectados a `webcamproduct:capture_MONO`
- **Consecuencia**: session_mic.wav y session_loop.wav son **byte-por-byte idénticos** (mismo contenido PCM)
- **Efecto en el feed**: "Remoto" nunca aparece aunque haya audio reproduciéndose por los audífonos

### ✅ Bugs menores resueltos en OpenCode
1. **7.3 — Botón "Preguntar"** — arreglado: `get_model()` respeta `auto/best-chat` del widget (antes hardcodeaba `gpt-4o-mini`); el protocolo ask.cmd de archivo único con carrera ahora usa marcadores separados `ask_start`/`ask_end` con `touch` sin truncado; el watcher maneja ambos en el mismo poll. Feedback visual: eventos info relevantes (ask/IA) aparecen en el feed como líneas sutiles centradas.

### ❌ Bugs menores pendientes
2. **Primera frase perdida** — arranque del capture ~2s más lento que el botón (pre-arrancar al abrir panel?)
3. **Scroll invertido** — el feed sube en vez de bajar con cada frase nueva (QML/Settings)
4. **Basura visual del feed anterior** — al iniciar nueva reunión, el feed arrastra texto de la anterior
5. **Frase final corrupta** — caracteres raros como "Toðallos mírs…" (posible IME/UTF-8 en el widget)

## Solución documentada para el problema del monitor BT

### Opción A (recomendada): `pw-record -P stream.capture.sink=true`
Fuente: https://stackoverflow.com/questions/78065207

```bash
# Captura lo que suena en el sink BT sin usar el monitor source
pw-record -P '{ stream.capture.sink=true node.target=bluez_output.84_AC_60_12_A9_31.1 }' \
  --rate 16000 --channels 1 --format s16 --latency 50ms /tmp/salida.wav
```

La flag `stream.capture.sink=true` le dice a PipeWire que capture el *playback* del sink en vez del monitor source, lo que evita el bug de routing.

### Opción B: `pw-loopback` como source virtual persistente
```bash
pw-loopback \
  --capture-props='{ stream.capture.sink=true node.target=bluez_output.84_AC_60_12_A9_31.1 }' \
  --playback-props='{ media.class=Audio/Source node.name=voxtype-loop-bt }'
```
Esto crea un source virtual (`voxtype-loop-bt`) que siempre captura el sink BT. Luego se graba con:
```bash
pw-record --target voxtype-loop-bt --rate 16000 --channels 1 --format s16 ...
```

## Prueba simple sugerida por el usuario (antes de tocar BT)

1. **Desconectar audífonos BT**, usar altavoces del monitor/PC
2. Mic fijo = webcam (ya está en settings)
3. Loop = "Monitor of …" del sink activo (el HDMI/analógico de los altavoces)
4. Reproducir un video de YouTube
5. Iniciar reunión desde el widget

**Lo que debería pasar**: el audio de YouTube sale por los altavoces → el monitor del sink lo captura → aparece como "Remoto" en el feed. Tu voz por la webcam → "Tú". Esta prueba valida TODO el pipeline (VAD, transcripción, feed, prioridad temporal) sin la complejidad del BT.

Si funciona, luego se implementa la Opción A o B para el BT.

## Código relevante

### `audio_capture.py` (~/repo/audit/)
- `LiveCapture.__init__`: `_mic_voice_at`, `_mic_suppress_secs = 2.0`
- `_feed_side`: actualiza `_mic_voice_at` en cada ventana de voz del mic (línea 416)
- `_close_side`: el loop se descarta si mic voz hace <2s (línea ~455-462)
- `_pw_record_start`: usa `pw-record --target <source> ...`
- `_watch_side`: lector con chunking limitado a 0.4s (fix backlog)

**Para implementar Opción A**: cambiar `_pw_record_start` para el lado loop a:
```python
if tag == "loop":
    cmd = [pw, "-P", '{ stream.capture.sink=true node.target=%s }' % src,
           "--rate", str(rate), "--channels", "1",
           "--format", "s16", "--latency", "50ms", str(out)]
```
donde `src` sería `bluez_output.84_AC_60_12_A9_31.1` (el sink, no el monitor).

### `auditor.py` (~/repo/audit/)
- `_transcribe`: recepción de frases → speaker "you" o "remote"
- `_has_recent`: red secundaria (texto duplicado ≤12s se descarta)
- `WhisperHTTP`: cliente multipart para whisper-server

### `Settings.qml`
- Selector de mic: filtra `bluez_input`
- Selector de loop: muestra sinks + sus monitores (pendiente adaptar a `stream.capture.sink=true`)

## Config actual del usuario
```json
{
  "auditorMicSource": "alsa_input.usb-webcamvendor_webcamproduct_YGR80PU1200...mono-fallback",
  "auditorLoopSource": "bluez_output.84_AC_60_12_A9_31.1.monitor",
  "auditorAiBaseUrl": "http://localhost:20128/v1",
  "auditorAiModel": "auto/best-chat",
  "auditorAutoReply": false,
  "auditorVaultSearch": true,
  "auditorKbThreshold": 70
}
```
API key → [REDACTED]

## Últimos commits
```
43fbf4d fix(auditor): rediseño anti-sidetone — prioridad temporal del mic (7.9)
c23fd13 fix(auditor): anti-sidetone HFP — buffer 1.2s + prioridad al mic (7.5)
48d934d fix(daemon): flags --mic-source/--loop-source van DESPUÉS de 'capture'
b7e07c0 feat(settings): sección audio en GUI + fuentes fijas + red anti-eco
```

## Referencias externas
- [PipeWire: capturar sink con pw-record](https://stackoverflow.com/questions/78065207) — flag `stream.capture.sink=true`
- [ArchWiki PipeWire/Examples](https://wiki.archlinux.org/index.php/PipeWire/Examples) — loopback, null-sink, echo-cancel
- [PipeWire props docs](https://docs.pipewire.org/devel/page_man_pipewire-props_7.html) — `stream.capture.sink`