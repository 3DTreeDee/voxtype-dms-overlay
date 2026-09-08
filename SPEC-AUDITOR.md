# Auditor de Reuniones — Spec de implementación

## Objetivo

Agregar al plugin **voxtype-dms-overlay** un **Auditor de reuniones** que, mientras se graba una reunión con voxtype (modo reunión, `meeting.audio = both`), analiza **en tiempo real** cada enunciado de **ambos lados** (tu mic + audio de sistema) y muestra en un **overlay** las preguntas detectadas y las respuestas/sugerencias (desde KB o IA).

## Cómo encaja en el plugin actual

El plugin tiene 2 mitades:
- **`OverlayDaemon.qml`** (daemon) — sigue el `state` file de voxtype (`$XDG_RUNTIME_DIR/voxtype/state`), publica `voxState`, captura rect de ventana, dispara el overlay de dictado. Es aquí donde se detecta el inicio de reunión y el flujo de audio.
- **`VoxTypeWidget.qml`** — widget de barra + control popout (reuniones, mic, output). Aquí se pone el **switch del auditor**.
- **`OverlayWindow.qml`** — overlay por pantalla (dim + mic + cutout). Modelo para el **overlay del auditor**.
- **`Settings.qml`** — panel de ajustes. Aquí va la **UI de config** de API keys/modelos.

## Stream en tiempo real

- Detectado el estado `meeting` (reunión activa), el daemon reacciona al transcript **chunked** de voxtype.
- voxtype escribe el transcript de reunión en `~/.local/share/voxtype/meetings/` (índice SQLite + chunks). La vía a tiempo real: vigilar el archivo/alm entregado por `voxtype meeting` (o el stream del daemon tras procesar cada chunk) y emitir cada enunciado (con lado/hablante) al overlay.
- Alternativa robusta: un **helper** (script/Python) que observe el transcript en vivo y publique eventos (enunciado + lado) para que el overlay los pinte y consulte KB/IA.

## Lado del enunciado (ambos)

- voxtype diarización **"You vs Remote"**: cada enunciado trae el lado (tú / remoto). El auditor procesa ambos.

## Flujo del auditor por enunciado

1. **Enunciado detectado** (+ lado, + timestamp).
2. **Buscar en KB** (notebook LLM → vault de Obsidian indexado con embeddings locales).
3. Si **match conalta confianza** → usar contenido de KB como sugerencia.
4. Si **no matchea** (bajo umbral) → **llamar a IA** (OmniRoute / OpenAI-compatible) con el enunciado → respuesta/sugerencia.
5. **Mostrar en el overlay** la pregunta (enunciado) + respuesta (de KB o IA), en tiempo real.

## Overlay de salida (tiempo real)

- Panel flotante (estilo OverlayWindow) que muestra la **cola de enunciados** recientes con su lado y la **respuesta del auditor** debajo de cada uno.
- **Switch** en el widget/daemon: activa/desactiva el divot auditor.
- Tema DMS (como VoxTypeOSD).

## UI de configuración

En `Settings.qml` (DMS Settings → Plugins):
- Modo API: **OmniRoute** o **OpenAI-compatible** (base URL + key).
- **Selección de modelos / combos**: qué modelo para tareas cortas vs. razonamiento/consulta KB.
- Umbral de confianza del KB.
- Carpetas del vault a indexar ("notebook LLM").

## Portabilidad

- Se mantiene el soporte de instalar como plugin DMS desde el repo del fork.
- Toda la config es por `pluginData` (por usuario), sin hardcodear API keys.
- La KB (vault) es por usuario/equipo — cada equipo configura su propio path.

## Estructura de código (fork del plugin)

```
voxtype-dms-overlay/
  OverlayDaemon.qml        # + detección reunión + stream enunciados
  OverlayWindow.qml       # + overlay del auditor (cola preguntas→respuestas)
  VoxTypeWidget.qml       # + switch del auditor en el popout
  Settings.qml            # + UI config API/combos/KB
  audit/
    auditor.py            # helper: observa transcript, consulta KB + IA
    kb_index.py           # embeddings + búsqueda en vault
    omniroute_client.py   # cliente OmniRoute/OpenAI-v1
    config.yaml           # modelos/combos, endpoints, umbral, paths
  scripts/
    voxtype-config-set    # (existente)
```

## Milestones

1. **[ ] Repo fork + rama feature + esta spec** — hecho.
2. **[ ] Helper Python del auditor** (observar transcript, KB, IA fallback) + CLI.
3. **[ ] Integración QML**: switch + overlay del auditor en vivo (daemon).
4. **[ ] UI de config** (API keys, modelos/combos, umbral, KB paths).
5. **[ ] Prueba con reunión real (ambos lados).**
6. **[ ] Portar/empaquetar para otros equipos.**