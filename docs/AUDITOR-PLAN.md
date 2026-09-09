# Auditor v2 — Plan por fases (push-to-ask + captions + setup OmniRoute GUI)

> Estado: **acordado con el usuario** (2026-09-08). Cada fase termina con una
> prueba end-to-end antes de pasar a la siguiente.

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

### Fase 5 — Pulido y registro
- Persistencia del transcript de captions (ya existe naming único por chunk).
- Ajustes de prompt (idioma, longitud máx, nº de captions de contexto).
- Documentación en repo + skill voxtype actualizada.

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

- **Latencia al soltar la tecla**: transcribir (~1s) + IA (~4-6s) → respuesta
  en ~6-8s. Mitigar: estado "pensando…" visible, y si hace falta streaming.
- **Preguntas de la persona Remota**: con push-to-ask el usuario repite la
  pregunta (o se captura por loopback si el remoto habla durante la
  pulsación). Confirmar si esto cubre el caso de uso.
- **No romper dictado normal**: ScrollLock dictado coexiste; el modo auditor
  es solo durante reunión activa.

## Referencia de arquitectura (sin cambios de diseño)

- audio_capture.py (chunks únicos, VAD RMS ≥0.003, dedupe SHA256)
- run.sh → lee plugin_settings.json → env OMNIROUTE_* (key nunca en argv)
- OverlayDaemon.qml → lanza capture/listen, guarda pluginData
- OverlayWindow.qml → panel grande con feed (anclas puras, 100% alto)
- Eventos JSONL: enunciado | kb_hit 📚 | ai_answer 💡 | ai_error | info
