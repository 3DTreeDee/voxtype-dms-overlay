# Handoff: Auditor de Reuniones — Estado desde OpenCode

> Documentado: 2026-09-09 ~07:50 local (sesión de ~3h en OpenCode)
> Rama: `feat/auditor-meetings`
> Repo: `~/Proyectos/GitHub/voxtype-dms-overlay`
> Plugin installed: `~/.config/DankMaterialShell/plugins/voxtypeOverlay/` (copias, NO symlink)
> Binario externo: `~/.local/bin/voxtype-export-mtg`

## 1. ESTADO ACTUAL ✅/❌

### ✅ Funciona (todo probado end-to-end)
- **Remote capture con BT** — `pw-record -P '{ stream.capture.sink=true node.target=<sink> }'` en vez de `--target <monitor>`. PipeWire re-ruteaba el monitor BT al source por defecto (webcam). Fix aplicado en `audio_capture.py::_pw_record_start` y `auditor.py::_start_ask_buffer`.
- **Push-to-ask "Preguntar"** — marcadores separados `ask_start`/`ask_end` (touch, sin truncado). Watcher tracking por índice (`ask_start_idx`) espera hasta 8s a que la frase se cierre VAD + whisper. Antes usaba un solo `ask.cmd` que perdía comandos por carrera y pw-record separado que PipeWire no alimentaba.
- **Vault_search toggle** — `run.sh` exporta correctamente `AUDITOR_VAULT_SEARCH=false` usando `eval + print('export VAR=val')` por stdout. Anteriormente: `os.environ[e]=val` dentro de `python3 -c` no salía del hijo python al shell padre → siempre `true`.
- **Modelo IA** — `omniroute_client.get_model` respeta `auto/best-chat` del widget (línea 82, usa `default_models[task]` como fallback). Antes hardcodeaba `gpt-4o-mini` → router respondía "no active credentials for openai".
- **Circuit breaker** — `_end_ask_rag` usa `safe_results = results if self.vault_search else []` para que ni `results` espurios generen 📚 si vault está OFF.
- **5 gates `vault_search`** — todas las emisiones `kb_hit` están gateadas. Verificar con `grep vault_search auditor.py`.
- **Orphan pw-record killer** — `LiveCapture.start()` mata cualquier pw-record apuntando a su tmp_dir antes de arrancar.
- **PID-unique WAVs** — `session_{run_id:06d}_{seq:05d}_{tag}.wav` y `phrase_{run_id:06d}_{seq:05d}_{ts}_{tag}.wav` — dos auditor.py nunca colisionan.
- **Graceful shutdown** — handler SIGTERM/SIGINT en `capture_live` → `cap.stop()` mata hijos pw-record.
- **session_log** — `MeetingAuditor.session_log` captura enunciados (ts exacto VAD) + respuestas IA. Se escribe como `/tmp/voxtype-auditor/session_transcript.json` al finalizar `capture_live`.
- **voxtype-export-mtg** — prefiere `session_transcript.json` con timestamps `[mm:ss.ms]` e incluye respuestas IA. Fallback al export de voxtype.
- **Scrolling corregido** — `OverlayWindow.qml:onCountChanged` usa `Qt.callLater(() => qlist.positionViewAtEnd())` (ya no está invertido).
- **Botón pregunta feedback** — eventos info relevantes (ask/IA) aparecen en feed como líneas sutiles centradas; `AuditorThread._isRelevantInfo` filtra.

### ❌ Bugs pendientes
1. **Primera frase perdida** — el arranque del capture tarda ~2s más que el botón de reunión. La primera frase que dices se pierde. Posible fix: pre-arrancar `LiveCapture` en idle al abrir el panel del auditor, o arrancar el capture antes de notificar al widget.
2. **Basura visual del feed anterior** — al iniciar una nueva reunión, el feed arrastra texto de la reunión anterior. `AuditorThread.events` no se limpia en `start()`. Fix: agregar `root.events = []` en `AuditorThread.start()`.
3. **Frase final corrupta** — caracteres raros como "Toðallos mírs…" en WM_STATUS/IME. Ocurre cuando el widget deja el IME/teclado virtual abierto. No es del auditor; es de VoxType o del widget cuando la reunión termina y el overlay reaparece.
4. **(Menor) Scroll invertido en Settings** — en la UI de Settings.qml, el scroll del feed sube en vez de bajar. No afecta al feed del overlay (que funciona bien).

## 2. HALLAZGOS CRÍTICOS (lecciones aprendidas)

### Bug #1 — run.sh: las env vars NUNCA llegaban al proceso
- **Código original**: `python3 -c "import os; os.environ['VAR']='val'"` — el `os.environ` solo modifica el proceso hijo python, no el bash padre. Al salir python3, todas las variables se pierden.
- **Fix**: `eval "$(python3 -c 'print("export VAR=val")')"` — python imprime exports que bash evalúa **antes del exec**.
- **Historia**: Hermes Agent implementó el run.sh original y nunca funcionó. `auditorAiApiKey`, `auditorVaultSearch`, `auditorAiModel` jamás llegaron al proceso. El modelo siempre caía a default `gpt-4o-mini`, vault asumía `true`, API key no se seteaba → IA fallaba → 📚 siempre.

### Bug #2 — Backticks `` ` `` en inline python rompen bash
- **Código original**: `python3 -c "...`val`... '`val` puede ser bool'..."` — los backticks hacen command substitution de bash dentro de las dobles comillas. Bash ejecutaba `val` e `if val:` como comandos → el bloque python fallaba silenciosamente.
- **Fix**: eliminar backticks de los comentarios (usar comillas simples o ninguna).

### Bug #3 — get_model hardcodeaba gpt-4o-mini
- `omniroute_client.py::get_model(task)` sin catálogo YAML (`self.models = {}`) devolvía `ModelConfig(name="gpt-4o-mini")` ignorando `default_models[task]`.
- El router OmniRoute responde `No active credentials for provider: openai` para `gpt-4o-mini` → la IA fallaba → el pipeline caía al `else` que hacía `_build_kb_context` sin gate → 📚.
- **Fix**: cuando `self.models` está vacío y `model_name` de `default_models` no está en catálogo, usar el nombre directamente.

### Bug #4 — Carrera en protocolo ask.cmd
- Un solo archivo `ask.cmd` sobreescrito con `echo -n > ask.cmd`. `onPressed` (async mkdir + callback) y `onReleased` podían colisionar: si sueltas antes de que se escriba `ask_start`, el watcher nunca lo ve; si ambos caen en el mismo ciclo de poll, `ask_end` se procesa con `_ask_buffering=False` y se descarta.
- **Fix**: marcadores separados `ask_start`/`ask_end` con `touch` (sin truncado, sin carrera).

### Bug #5 — Orphan pw-record + session file collision
- Cuando el daemon mata auditor.py (SIGKILL o `proc.running=false`), los hijos pw-record sobreviven y siguen escribiendo el mismo `session_00001_*.wav`. 3 generaciones de huérfanos escribiendo al mismo archivo → audio corrupto → frases de Remote nunca se cierran.
- **Fix**: (a) PID en nombres de archivo, (b) startup killer de orphans, (c) handler SIGTERM que deriva a `cap.stop()`.

### Bug #6 — pw-record separado para push-to-ask no funciona
- PipeWire no alimenta dos capturas de la misma fuente. El VAD principal ya tiene el source → el segundo pw-record del ask recibe silencio → WAVs vacíos → "no se detectó voz".
- **Fix**: usar las frases ya transcritas por el VAD principal (`self._spoken`) durante la pulsación.

### Bug #7 — Timestamps de voxtype son chunks fijos de 30s
- voxtype genera segmentos en bloques de 30s (`chunk_duration_secs = 30`), NO por VAD. El transcript.json se escribe al hacer stop, no en tiempo real.
- El auditor captura con timestamps exactos de VAD (ms). Se guarda en `session_transcript.json` y `voxtype-export-mtg` lo prefiere.

## 3. ARQUITECTURA ACTUAL

### Flujo de inicio de reunión (OverlayDaemon.qml -> startAuditor)
1. `voxtype meeting start` — inicia grabación de voxtype (respaldo completo, chunks de 30s)
2. Tras 2s, lanza `auditor.py capture ...` vía `AuditorThread`
3. `run.sh` exporta env vars (eval + print), luego exec `auditor.py`
4. `auditor.py capture` arranca `whisper-server` si no está, luego `LiveCapture` (pw-record continuo por lado)
5. Lector VAD cierra frases, las transcribe con whisper, emite eventos JSONL
6. `AuditorThread` recibe eventos, los muestra en el feed (OverlayWindow)
7. Botón Preguntar → marcadores ask_start/ask_end → watcher recolecta `_spoken` + IA
8. Al detener: SIGTERM → `finally` → `cap.stop()` → matar pw-record → escribir `session_transcript.json`

### Archivos clave
| Archivo | Rol |
|---------|-----|
| `audit/audio_capture.py` | LiveCapture: pw-record continuo, VAD, cierre de frases |
| `audit/auditor.py` | Orquestador: transcripción whisper, RAG, push-to-ask, session_log |
| `audit/omniroute_client.py` | Cliente IA con get_model, retry, timeout |
| `audit/run.sh` | Exporta env vars del widget al proceso auditor |
| `audit/kb_index.py` | Embeddings del vault, búsqueda semántica |
| `OverlayDaemon.qml` | Coordinador: inicia/para el auditor, maneja overlay visual |
| `OverlayWindow.qml` | Feed visual del auditor + botón Preguntar |
| `auditor_components/AuditorThread.qml` | Proceso + SplitParser + cola de eventos |
| `Settings.qml` | UI de configuración (audio, IA, vault) |
| `~/.local/bin/voxtype-export-mtg` | Exporta reunión a vault (prefiere session_transcript.json) |

### Config actual del usuario (plugin_settings.json -> voxtypeOverlay)
```json
{
  "auditorMicSource": "alsa_input.usb-webcamvendor_webcamproduct_...mono-fallback",
  "auditorLoopSource": "bluez_output.84_AC_60_12_A9_31.1.monitor",
  "auditorAiBaseUrl": "http://localhost:20128/v1",
  "auditorAiModel": "auto/best-chat",
  "auditorAutoReply": false,
  "auditorVaultSearch": false,
  "auditorKbThreshold": 93
}
```
API key en plugin_settings.json (no visible en comando).

## 4. QUÉ SIGUE (tareas para mañana)

### Prioridad Alta
1. **Fix primera frase perdida** — el capture arranca ~2s después del botón. La primera frase que dices se pierde porque los pw-record no están grabando todavía. Opciones:
   - Pre-arrancar `LiveCapture` en modo idle cuando se abre el panel del auditor (antes de presionar "Iniciar reunión")
   - O arrancar el capture y esperar a que los pw-record estén activos antes de decirle al widget que la reunión empezó
   - O hacer que el daemon arranque el capture antes de `voxtype meeting start`

2. **Fix basura visual del feed anterior** — `AuditorThread.qml` no limpia `events` al arrancar. Agregar `root.events = []` al inicio de `start()` (línea ~89). También limpiar `daemon._spoken = []` en `startAuditor` del daemon.

3. **Frase final corrupta** — investigar si es del widget de VoxType (reaparece al terminar reunión) o del IME. Verificar si cerrar el teclado virtual al finalizar la reunión lo soluciona. Si es del overlay, el fix está en OverlayWindow, no en el auditor.

### Prioridad Media
4. **ScrollSettings invertido** — en `Settings.qml`, la vista previa del feed tiene scroll invertido (se va arriba). Es de la UI de settings, no del feed real. Bajo impacto.

5. **Commit de voxtype-export-mtg** — está fuera del repo (en ~/.local/bin). Considerar moverlo al repo en `scripts/` y hacer que el daemon lo instale/symlinkee.

6. **Push a origin** — la rama `feat/auditor-meetings` tiene commits locales sin push. Hacer `git push origin feat/auditor-meetings` para respaldo.

### Consideraciones técnicas
- El plugin instalado en `~/.config/DankMaterialShell/plugins/voxtypeOverlay/` es una **copia**, no symlink al repo. Los cambios QML hay que copiarlos manualmente (`cp OverlayWindow.qml ...`). Los cambios Python corren desde el repo via run.sh.
- Después de copiar QML, recargar con `dms ipc plugin-scan reload voxtypeOverlay` o reiniciar DMS.
- `__pycache__` en el directorio instalado puede causar que corra código viejo. Limpiar con `rm -rf .../__pycache__` y opcionalmente `find ... -name '*.pyc' -delete`.

## 5. ÚLTIMOS COMMITS
```
c4e893d feat(auditor): session_log guarda transcript exacto en session_transcript.json
2459cf9 fix(auditor): push-to-ask funcional + vault_search obedece al widget
76c47c9 fix(auditor): captura remoto BT con stream.capture.sink + mata huérfanos pw-record
43fbf4d fix(auditor): rediseño anti-sidetone — prioridad temporal del mic (7.9)
c23fd13 fix(auditor): anti-sidetone HFP — buffer 1.2s + prioridad al mic (7.5)
```

## 6. REFERENCIAS
- [PipeWire: capturar sink con pw-record](https://stackoverflow.com/questions/78065207) — flag `stream.capture.sink=true`
- [ArchWiki PipeWire/Examples](https://wiki.archlinux.org/index.php/PipeWire/Examples) — loopback, null-sink, echo-cancel
- [PipeWire props docs](https://docs.pipewire.org/devel/page_man_pipewire-props_7.html) — `stream.capture.sink`