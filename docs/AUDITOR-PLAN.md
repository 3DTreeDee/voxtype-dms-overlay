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
- **Causa raíz probable**: (a) whisper-server hace auto-detección de idioma
  por defecto y falla con frases cortas/acento (ya medido: reportó `lang=en`
  con audio real en español); (b) las "repeticiones" = mismo audio entrando
  por los DOS lados (ver 7.2) + posibles cortes del VAD por micro-pausas.
- **Fix propuesto**: pasar `language=es` por defecto al POST /inference
  (configurable: `AUDITOR_WHISPER_LANG`, vacío = auto). Validar con voz real:
  5 frases en español → 5 captions correctas sin repetición (tras 7.2).

#### Issue 7.2 — Frase propia duplicada: primero "you", luego "remote"
- **Síntoma** (usuario): "cuando detectaba algo que yo decía lo señalaba como
  mío y luego lo repetía con el texto de remoto".
- **Causa raíz** (código + evidencia): con el sink por defecto SUSPENDED
  (nada sonando por altavoces — no había remoto), `pw-record --target` del
  monitor del sink resuelve **silenciosamente al source por defecto = ¡el
  mic!** → la misma voz se graba por ambos lados; el dedupe por hash
  byte-idéntico falla porque son dos grabaciones independientes del mismo
  source (timing/niveles distintos).
- **Fix propuesto (elegir 1, validar, luego los demás si hiciera falta)**:
  a) comprobar estado del sink antes de abrir el lado Remote: si está
  SUSPENDED → no abrir loopback (lado Remote inactivo hasta que suene algo);
  b) apuntar al monitor por nombre exacto (`<sink>.monitor`) en vez de
  `--target <default>`; c) dedupe textual: si ambos lados producen el MISMO
  texto transcrito en ventana ~3s, descartar el 2º (eco).

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
2. ¿El RAG automático actual se elimina por completo (default) o queda detrás
   de un toggle OFF por defecto?
   → **RESUELTO**: toggle "Respuestas automáticas" en Settings, **default OFF**
   (se conserva el RAG actual disponible).
3. Contexto enviado a la IA: ¿últimas N frases (¿cuántas?) o toda la reunión?
   → **RESUELTO**: últimas **~10 frases** de la reunión + lo hablado durante
   la pulsación.
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
