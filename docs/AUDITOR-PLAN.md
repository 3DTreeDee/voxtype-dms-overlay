# Auditor v2 — Plan por fases (push-to-ask + captions + setup OmniRoute GUI)

> Estado: **acordado con el usuario** (2026-09-08). Cada fase termina con una
> prueba end-to-end antes de pasar a la siguiente.

## Estado

- **Fase 1** ✅ Botón "Probar conexión" + estado en Settings ✓ (commit `03d0733`)
- **Fase 2** ✅ Dropdown dinámico de modelos tras check exitoso ✓ (commit `cdbb32b`)
- **Fase 3** ✅ Toggle respuestas automáticas / captions-only ✓ (commit `dc0cb03`)
- **Fase 4** ✅ Push‑to‑ask con botón en panel ✓ (commit `6d5ebc9`)
- **Fase 5** ✅ Captions rápidos + RAG inteligente ✓ (commit `11d8845`)
- **Fase 6** ✅ Motor de transcripción persistente whisper.cpp+Vulkan (reemplaza
  `voxtype transcribe`) + captura por fin-de-frase con VAD — arquitectura
  aprobada por el usuario (2026-09-09). Validada end-to-end con voz real
  (3/3 frases, ~1.3s tras callar) ✓ (commits `f9efc6c`, `31d3e1b`)
- **Fase 7** 🚧 Correcciones post-prueba real — 3 issues: 7.1 español→inglés
  repetido, 7.2 duplicado you→remote, 7.3 botón preguntar sin respuesta

## Visión

El auditor deja de "escuchar y responder" constantemente por ambos lados.
Nuevo comportamiento:

1. **Closed captions (siempre)**: transcribe la interacción entre Tú y la
   persona Remota y la muestra en el feed del panel, SIN llamadas a la IA.
2. **Push-to-ask (bajo demanda)**: al mantener presionada una tecla se graba
   (mic + loopback), al soltarla se transcribe y se envía a la IA como prompt,
   junto con el contexto de la conversación (captions previas). La IA busca en
   el vault de Obsidian (RAG) o responde con su conocimiento. La respuesta
   aparece en el feed.
3. **Setup OmniRoute desde GUI**: botón "Probar conexión" que valida la API y,
   si funciona, despliega una lista con los modelos disponibles para elegir.

## Por qué este diseño es más fiable que el actual

- El problema del RAG automático era **detectar la intención**: el auditor no
  sabía si un enunciado era pregunta, y las referencias ("eso", "¿y cuánto
  sale?") requerían contexto. El push-to-ask hace la pregunta **explícita y
  con contexto completo** → mejor query, mejor respuesta, cero ruido.
- Costo/latencia: 2 llamadas IA × cada enunciado relevante desaparecen; solo
  se llama a la IA cuando el usuario decide.
- Los captions son útiles por sí solos (registro visual de la reunión).

## Fases

### Fase 1 — Botón "Probar conexión OmniRoute" en Settings
- Botón en Settings.qml (sección Auditor IA) que ejecuta una prueba de
  conexión con base_url + key guardadas en plugin_settings.
- Implementación: subcomando `test` del helper (python hace GET /v1/models) o
  HttpLoader desde QML. Feedback visual: ✓ conectado (latencia, modelo
  actual) / ✗ error detallado.
- **Prueba**: clic en Settings → indicador verde con "Conectado a
  localhost:20128".

### Fase 2 — Lista desplegable de modelos tras check OK
- Si Fase 1 pasa, se rellena un ComboBox con los modelos del catálogo
  (`/v1/models`), priorizando aliases `auto/*`, luego el resto agrupado.
- Seleccionar escribe `auditorAiModel` en pluginData (mismo key que ya usa el
  daemon). Default recomendado: `auto/best-chat` (benchmark real: 3.5s, mejor
  resolución de referencias).
- **Prueba**: check → dropdown poblado → elegir modelo → se guarda.

### Fase 3 — Captions-only (quitar RAG automático del capture)
- El modo `capture` actual (chunks + VAD + transcribe + RAG por enunciado) se
  simplifica a **transcribir y emitir enunciados** (closed captions), sin
  `process_utterance` IA por cada lado.
- Se conserva opcional (toggle en Settings, default OFF) la respuesta
  automática KB-por-similitud si más adelante se quiere.
- **Prueba**: reunión real → el feed muestra solo la conversación, sin
  respuestas 📚/💡 automáticas.

### Fase 4 — Push-to-ask
- Tecla configurable (candidata: ScrollLock ya usada para dictado; en modo
  reunión pasa a ser push-to-ask, o tecla nueva configurable en Settings).
- Mientras está presionada: grabar mic + loopback (reusar audio_capture,
  chunks) — **captura CUALQUIER pregunta que se emita por audio, tanto del
  Remoto (loopback) como del usuario (mic), de forma transparente: se
  sostiene la tecla mientras se formula la pregunta quien sea**. Al soltar:
  transcribir (daemon voxtype residente, ~1s) y enviar a la IA:
  - Contexto: captions previas (últimas N frases de la reunión) + lo hablado
    durante la pulsación.
  - La IA analiza, refina query, busca en el vault (RAG) o responde con su
    conocimiento.
- Feedback en el feed/panel: estado "🎤 preguntando…" → "💭 pensando…" →
  respuesta 📚/💡 (reusar tipos de evento existentes). Aviso visual de que
  puede hablar (lección de UX: avisar cuándo hablar).
- También un botón "Preguntar" en el panel (alternativa a la tecla, para
  ratón).
- **Prueba**: sostener tecla → hablar pregunta → soltar → respuesta con
  fuentes del vault en <10s.

### Fase 6 — Motor persistente whisper.cpp+Vulkan + captura por fin-de-frase

**Problema que resuelve**: `voxtype transcribe` (motor del `capture` en Fases 3-5)
recarga el modelo GGML en cada invocación (~2.7s de carga + ~1.5s de inferencia
≈ 4.3s/caption — benchmark 2026-09-09) → impracticable para captions en vivo.

**Motor elegido (validado con voz real del usuario)**:

- **whisper.cpp compilado desde fuente con `GGML_VULKAN=ON`** → usa la AMD
  RX 6650 XT (RADV NAVI23): encode 380ms vs 10,700ms CPU (28×).
- **`whisper-server`** (daemon HTTP que viene con whisper.cpp): carga el modelo
  `ggml-large-v3-turbo.bin` UNA vez en VRAM (~2.7s al arrancar, 1.6GB en
  Vulkan0) y responde en **~400-660ms por transcripción** con modelo caliente.
  Endpoint: `POST /inference` (multipart) + `GET /health`.
- Instalado en `~/.local/share/whisper-cpp/` (`cmake --install`, rpath vacío →
  lanzar con `LD_LIBRARY_PATH=.../lib`).
- Mismo modelo large-v3-turbo que ya usa voxtype → **fiabilidad y puntuación
  idénticas a lo conocido** (decisión: fiabilidad pesa más que velocidad).

**Captura por fin-de-frase (VAD), no chunks fijos**: en vez de grabar 2s y
transcribir, la captura corre **pw-record continuo por lado** (mic → You,
loopback → Remote) y un lector detecta silencio sostenido (~0.8s) tras voz →
cierra la frase y la envía a transcribir. Latencia percibida: **fin de frase
+ ~0.5-1s** (en vez de 2s fijos de chunk). Frases largas (≥15s) se cortan por
timeout para no perder audio.

**Por qué NO parakeet.cpp streaming** (evaluado 2026-09-09, descartado):
- `parakeet_realtime_eou_120m-v1` (el modelo streaming de parakeet.cpp): solo
  inglés, sin puntuación ni mayúsculas, WER alto (modelo 5× menor).
- `nemotron-3.5-asr-streaming-0.6b` (multilingüe): habría que validarlo; la
  ganancia vs whisper-server es ~0.5s de latencia a cambio de fiabilidad
  desconocida — contrario a la prioridad del usuario.

**Cambios en el código**:
- `audio_capture.py`: `LiveCapture` pasa de chunks de duración fija a captura
  continua + corte por fin-de-frase (VAD por RMS, sin solape perdido).
- `auditor.py`: nuevo motor `_transcribe_wav_http` (POST al whisper-server vía
  aiohttp); `capture_live` arranca el daemon si no responde en el puerto
  (health check) y lo usa para captions Y push-to-ask. Fallback: `voxtype
  transcribe` si el server no puede arrancar.
- `OverlayDaemon.qml`: `startAuditor` lanza el auditor en modo `capture`
  (en vez de `live`), manteniendo `voxtype meeting start` como grabación
  completa de respaldo (la que se exporta/indexa para RAG).

**Prueba**: reunión real → el feed muestra captions por frase en ~1s tras
callar, con puntuación y ES/EN; `voxtype meeting stop` sigue exportando la
transcripción completa.

### Fase 5 — Pulido y registro
- Persistencia del transcript de captions (ya existe naming único por chunk).
- Ajustes de prompt (idioma, longitud máx, nº de captions de contexto).
- Documentación en repo + skill voxtype actualizada.

### Fase 7 — Correcciones post-prueba real (reunión 08:12, 1m43s) 🚧

**Contexto**: primera reunión real con Fase 6 tras reiniciar DMS (que tenía el
código viejo en memoria). El transcript de respaldo (voxtype) capturó bien el
español; el feed en vivo mostró 3 problemas. Se resuelven **uno a uno con
prueba por fase** (regla del usuario, 2026-09-09).

#### Issue 7.1 — Español transcrito en inglés y repetido varias veces
- **Síntoma** (usuario + imagen): la primera frase en español apareció en el
  feed repetida varias veces, en inglés.
- **Causa raíz**: (a) whisper-server hace auto-detección de idioma por defecto
  y falla con frases cortas/acento (ya medido: reportó `lang=en` con audio real
  en español); (b) las "repeticiones" = mismo audio entrando por los DOS lados
  (ver 7.2).
- **Fix APLICADO ✅**: `WhisperHTTP` envía `language=es` por defecto al POST
  /inference (env `AUDITOR_WHISPER_LANG`; vacío = auto). Validado con voz
  real: texto español correcto en 0.61s. Pendiente validar en reunión real.

#### Issue 7.2 — Frase propia duplicada: primero "you", luego "remote"
- **Síntoma** (usuario): "cuando detectaba algo que yo decía lo señalaba como
  mío y luego lo repetía con el texto de remoto".
- **Causa raíz**: con el sink por defecto SUSPENDED (nada sonando por
  altavoces — no había remoto), la heurística de `_default_loopback_source`
  elegía un monitor que recibía el MISMO mic (monitorización de voxtype o
  resolución de pw-record al source por defecto) → la misma voz se grababa por
  ambos lados; el dedupe por hash byte-idéntico no los detecta (dos grabaciones
  independientes del mismo source, timing/niveles distintos).
- **Fix APLICADO ✅ (doble, requisito del usuario 2026-09-09 "que respete la
  opción preconfigurada de altavoces y micrófono por defecto desde el widget,
  que no vaya haciendo switch" — sus audífonos BT cambian el default)**:
  1. **Fuentes FIJAS desde GUI**: Settings → VoxType → "Micrófono del auditor
     (lado Tú)" y "Altavoces del auditor (lado Remoto)" (dropdowns poblados de
     PipeWire vía pactl + botón Refrescar). OverlayDaemon pasa
     `--mic-source`/`--loop-source` al capture cuando están definidas → el
     auditor usa EXACTAMENTE esas fuentes, sin re-resolver el default de
     PipeWire en cada arranque. Valor vacío = "System default" (resolución
     única al arrancar, comportamiento previo).
  2. **Dedupe textual anti-eco** en `capture_live`: ventana de 12s de
     transcripciones; si el texto normalizado (lower/acentos/puntuación)
     coincide con uno reciente del OTRO lado → eco descartado (también mismo
     lado en <3s = artefacto VAD). Validado 4/4 casos de prueba.
- **Comportamiento con dispositivo fijo no disponible** (p.ej. BT apagado):
  el lado Remote queda inactivo (pw-record falla solo en ese lado); el lado
  Tú sigue funcionando. NO switchea a otro dispositivo.

#### Issue 7.4 — Capture moría al arrancar desde el widget (nada en el feed)
- **Síntoma** (reuniones 08:32/08:33): el usuario configura las fuentes en
  Settings, inicia reunión, habla → el feed NO muestra nada (el transcript de
  respaldo de voxtype sí captura).
- **Causa raíz**: el daemon construía `run.sh --mic-source X --loop-source Y
  capture` — pero esos flags pertenecen al SUBPARSER `capture` de argparse →
  "unrecognized arguments", exit 2, proceso muerto al nacer. `--vault` sí es
  del parser principal (por eso solo fallaba con fuentes fijas).
- **Fix APLICADO ✅** (commit `48d934d`): los flags se concatenan SIEMPRE
  después de `"capture"`. Validado manualmente: el capture con las fuentes del
  usuario transcribe en vivo (español correcto con language=es).
- **Lección**: en argparse, los flags de un subparser NO pueden preceder al
  nombre del subcomando. Al construir comandos en QML, mantener el orden
  `[parser-principal flags] comando [subparser flags]`.

#### Issue 7.5 — La voz del usuario sale como "Remoto" (perfil HFP / sidetone BT)
- **Síntoma** (prueba 08:55): TODAS las frases del usuario aparecen como
  "Remoto" y casi nunca como "Tú". Evidencia: los WAVs del lado loop
  (monitor BT) contienen SU voz ("Eso fue una prueba de pregunta...", "Voy a
  terminar la reunión").
- **Causa raíz** (pistas del usuario): en llamadas (Google Meet), los
  audífonos BT cambian a perfil HFP (manos libres) → el mic BT se activa y el
  perfil realimenta la propia voz del usuario al sink (sidetone). El monitor
  BT (lado Remote) capta su voz con ~0 ms de retardo respecto al mic webcam
  (evidencia: frases loop y mic cerradas al mismo milisegundo). El dedupe
  anti-eco (7.2) descartaba al que llegaba SEGUNDO → si el loop llegaba 1 ms
  antes, se descartaba el "you" y se emitía el "remote". Resultado: todo como
  Remoto.
- **Fix APLICADO ✅** (commit pendiente):
  1. **Preferencia "you"**: ante texto idéntico en ambos lados, gana SIEMPRE
     el mic (you); el remote es el eco descartable (nunca al revés).
  2. **Buffer anti-sidetone**: la frase "remote" se retiene 1.2 s antes de
     emitirse; si llega el "you" gemelo en esa ventana, el remote se anula
     (voz real del interlocutor = texto distinto → se emite normal).
  3. **Selector de mic sin BT**: Settings.qml excluye `bluez_input*` del
     dropdown de micrófono (solo mics físicos webcam/USB + System default).
- **Pendiente de validación**: prueba en vivo del usuario (con y sin llamada).

#### Issue 7.9 — REDISEÑO: prioridad temporal del mic (reemplaza el fix de 7.5)
- **Por qué**: el enfoque de 7.5 (buffer 1.2s + dedupe textual) seguía siendo
  frágil: depende de que mic y loop segmenten el audio IGUAL (misma frase,
  mismo texto). La prueba 09:08 lo demostró: el mic produjo UNA frase gigante
  de 109s (backlog del lector del WAV) mientras el loop cerraba frases cortas
  → el buffer no emparejó nada → todo salió "Remoto" otra vez.
- **Causa del fallo de segmentación**: el lector de `_watch_side` leía TODO el
  backlog de una vez (`f.read(size - read_pos)`): si se atrasaba, un backlog de
  minutos entraba en UN chunk → frase de 109s y el tope de 15s inútil.
- **Rediseño aplicado ✅**:
  1. **Regla temporal en `audio_capture.py`**: el VAD del mic actualiza
     `_mic_voice_at` (monotonic) con cada ventana de voz. Si el lado loop
     cierra una frase con el mic hablando hace <2s → se descarta SIN
     transcribir (sidetone/eco de la voz del usuario — perfil BT HFP).
     El Remote solo se emite con el mic en silencio ≥2s = voz real del
     interlocutor. Ya NO depende de que ambos lados segmenten igual.
  2. **Fix backlog**: lectura limitada a ~0.4s por iteración (`read_pos +=
     len(chunk)`) → el VAD corta frases razonables aunque el lector se atrase.
  3. **`auditor.py` simplificado**: sin buffer de 1.2s; red secundaria = si el
     texto del remote ya lo emitió el you ≤12s, descartar (eco con retardo).
- **Pendiente de validación**: prueba en vivo (usuario hablando con BT puestos
  y algo sonando por el sink: su voz debe salir SIEMPRE como "Tú").

#### Issues del feed detectados en la prueba 08:55 (pendientes)
- **7.6 — Texto de la sesión anterior visible al iniciar**: el feed conserva
  captions viejos al abrir una reunión nueva (el usuario ve "texto anterior"
  mezclado). Fix propuesto: limpiar el feed al iniciar reunión (daemon).
- **7.7 — Scroll del feed hacia arriba**: en cada frase nueva el transcript
  "se sube" (auto-scroll al revés o al inicio); debe auto-scrollear al final
  para mostrar la frase nueva. Fix propuesto: en OverlayWindow, tras append,
  posicionar el scroll/ListView al final.
- **7.8 — Transcripción corrupta al cierre**: la última frase dicha al parar
  ("Todos mis reproductores estaban pausados") salió con caracteres extraños
  ("Toðallos mírs reproduktores staðan pausaðus" — patrón islandés ð/í).
  Hipótesis: frase cortada por el cierre + sin language=es aplicado (¿último
  request con auto-detect?). Verificar en cierre ordenado.

#### Issue 7.3 — Botón "Preguntar": no se ve la respuesta de la IA
- **Síntoma** (usuario): presiona preguntar y no aparece respuesta en el feed.
- **Causa raíz probable**: aún sin diagnosticar. Hipótesis: fallo/timeout del
  LLM (OmniRoute 20128, modelo auto/best-chat), evento `ai_error` no
  renderizado, o la respuesta llega pero no se ve (viewport/auto-scroll —
  patrón conocido del usuario).
- **Bloqueante de diagnóstico**: el stderr del auditor solo se captura al
  TERMINAR el proceso (StdioCollector onStreamFinished en AuditorThread.qml)
  → los logs en vivo de `capture_live` se pierden durante la reunión.
- **Fix propuesto**: (0) log del capture a archivo
  (`~/.local/share/voxtype-auditor/live.log`, rotado) para diagnosticar; (1)
  probar push-to-ask fuera de reunión (misma ruta LLM) y ver si OmniRoute
  responde; (2) revisar render de `ai_answer`/`ai_error` en OverlayWindow.

**Prueba por fase**: tras cada fix → reunión real corta desde el widget (el
usuario habla 3 frases en español + 1 push-to-ask) → validar en el feed.

## Decisiones abiertas (a confirmar con el usuario)

1. ¿Tecla del push-to-ask: reutilizar ScrollLock en modo reunión, o tecla
   dedicada configurable?
   → **RESUELTO (2026-09-08)**: reutilizar **ScrollLock en modo reunión** como
   push-to-ask (el push-to-talk de dictado pasa a ser push-to-ask durante
   reuniones activas), **+ botón "Preguntar" en el panel** para ratón.
   → **ACTUALIZADO (Sprint 1, 2026-09-11)**: se eliminó mantener presionado.
   El panel usa un clic en **“Sugerir”**; ScrollLock vuelve a ser solo dictado
   normal.
2. ¿El RAG automático actual se elimina por completo (default) o queda detrás
   de un toggle OFF por defecto?
   → **RESUELTO**: toggle "Respuestas automáticas" en Settings, **default OFF**
   (se conserva el RAG actual disponible).
3. Contexto enviado a la IA: ¿últimas N frases (¿cuántas?) o toda la reunión?
   → **RESUELTO**: últimas **~10 frases** de la reunión + lo hablado durante
   la pulsación.
   → **ACTUALIZADO (Sprint 1, 2026-09-11)**: se eliminó la pulsación larga.
   “Sugerir” usa un clic, crea una solicitud explícita y responde con las
   últimas 10 frases + contexto. ScrollLock vuelve a ser solo dictado normal.
4. ¿El botón "Probar conexión" va en Settings (panel DMS) o en el popout del
   widget de barra?
   → **RESUELTO**: en **Settings → Plugins → VoxType**, junto a los campos de
   base URL / key / modelo.

## Riesgos y mitigaciones

- **Latencia al soltar la tecla**: transcribir (~0.5s con whisper-server) + IA
  (~4-6s) → respuesta en ~5-7s. Mitigar: estado "pensando…" visible, y si hace
  falta streaming.
- **whisper-server no está corriendo al iniciar reunión**: `capture_live` hace
  health check y lo arranca él mismo (carga del modelo ~2.7s → primera caption
  tarda ~3-4s; aceptable, nadie habla en el segundo 0 y voxtype meeting ya
  graba el respaldo completo). Al salir, lo detiene si él lo lanzó.
- **Preguntas de la persona Remota**: con push-to-ask el usuario repite la
  pregunta (o se captura por loopback si el remoto habla durante la
  pulsación). Confirmar si esto cubre el caso de uso.
- **No romper dictado normal**: ScrollLock dictado coexiste; el modo auditor
  es solo durante reunión activa. whisper-server ocupa ~1.6GB de VRAM solo
  durante la reunión (se cierra al salir).
- **VRAM 8GB**: si `voxtype meeting start` corre en paralelo, voxtype usa su
  propia gestión (Whisper/Parakeet). whisper-server comparte GPU vía Vulkan;
  si hubiera contención, voxtype queda configurado para CPU + diarización
  simple (tradeoff aceptado).

## Referencia de arquitectura (sin cambios de diseño)

- audio_capture.py (captura continua, corte por fin-de-frase: VAD RMS ≥0.003,
  silencio ≥0.8s cierra frase, tope 15s; dedupe SHA256 byte-idéntico mic/loop)
- run.sh → lee plugin_settings.json → env OMNIROUTE_* (key nunca en argv)
- OverlayDaemon.qml → lanza capture/listen, guarda pluginData
- OverlayWindow.qml → panel grande con feed (anclas puras, 100% alto)
- whisper-server: `~/.local/share/whisper-cpp/bin/whisper-server` +
  `LD_LIBRARY_PATH=~/.local/share/whisper-cpp/lib`; modelo
  `~/.local/share/voxtype/models/ggml-large-v3-turbo.bin`; puerto 8177
- Eventos JSONL: enunciado | kb_hit 📚 | ai_answer 💡 | ai_error | info
