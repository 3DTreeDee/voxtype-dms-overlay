# Atril — Asistente de Reuniones (fork voxtype-dms-overlay)

> Estado: **PLAN COMPLETO** (2026-09-11, sesión Hermes). Decisiones cerradas;
> listo para arrancar en OpenCode.
> Rama: `feat/auditor-meetings`
> Repo: `~/Proyectos/GitHub/voxtype-dms-overlay`
> Fuentes: `docs/AUDITOR-PLAN.md` (fases 1-7), `docs/BUGS-AUDITOR.md` (B01-B10),
> `docs/HANDOFF-OPENGODE.md`.

## 1. Visión de producto

Dejar de ser un "overlay de voxtype" y convertirse en un **asistente de reuniones
completo, 100% local/open-source/gratis**, que cubre el ciclo: preparar → estar en
la reunión → recap después → aprender y seguir.

Diferencial real vs competencia (Cluely $20-75/mes, FinalRound $25/mes, ambos cloud):
**indetectable en screen-share (ya por layer-shell Wayland) + RAG sobre conocimiento
propio (vault Obsidian / OpenNotebook) + local + gratis + extensible.**

## 2. Prioridades del usuario (resumen de la sesión)

| # | Feature | Prioridad |
|---|---------|-----------|
| 7 | Modo debug (latencia, reasoning, tokens, métricas) | **ALTA — lo primero** |
| 8 | Botón "Sugerir" (renombrar "Preguntar"; single-click, sin mantener) | **ALTA** |
| 14 | Streaming de IA + render tokens progresivos | **ALTA — "ya"** |
| 1 | Verbosidad del transcript (Corto/Medio/Detallado) | **ALTA** |
| 2+6 | Integración OpenNotebook **vía API REST** (no MCP) + selector de notebook | **ALTA** |
| 9 | Config de modelo Whisper | Media |
| 10 | Benchmark periódico de IA + fallback automático | Media |
| 11+8 | Summarize periódico + botón "Recap" | Media |
| 8 | Indetectable a screen-share (verificar) | Media |
| 15 | Post-reunión: recap + puntos a mejorar + fuentes | Baja |
| 3 | Modo "Preparar reunión" (ensayo/entrevista) | Baja |
| 4 | Reorganizar UI en acordeones | Baja |
| 5 | Selector de timeline en el feed | Baja |
| 8 | Contexto visual (screen) | Baja |
| 13 | ASCII art con nuevo nombre | Cuando exista la TUI |
| 12 | Detección en vivo de fallos de datos | **Muy baja** (experimental) |

## 3. Decisiones registradas (de la sesión de trazado)

1. **Integración OpenNotebook por API REST**, NO por MCP. El auditor habla con
   OpenNotebook vía HTTP (`/api/search`, `/api/ask`, `/api/notebooks`), no como
   cliente MCP. El MCP es para agentes tipo Hermes; el helper Python usa REST.
2. **Botón** → renombrado **"Sugerir"** (no "Ayuda", no "¿Qué digo?").
3. **Push-to-ask = single click, sin mantener presionado.** La IA ya responde la
   pregunta en el contexto de la conversación (validado: dijiste "ajá" pero
   respondió la última pregunta). Se elimina el comportamiento de mantener la
   tecla; un clic en "Sugerir" toma la transcripción reciente + contexto y
   responde.
4. **Modelo IA principal**: OmniRoute `auto/best-chat` queda como primario
   (calidad). El local-pequeño es *fallback futuro*, sinónimo con la idea #10
   (cuando se acaben créditos / no responda). Se alinea con el OPI + NPU cuando
   esté migrado a Armbian.
5. **OpenNotebook se ejecuta en el PC por ahora**; migrar al OPI cuando termine
   la instalación de Armbian (decisión del usuario, 2026-09-11).
6. **Streaming de IA = prioridad de sprint 1**: implementar
   `chat_completion_stream` (hoy `NotImplementedError` en
   `omniroute_client.py:167`) y renderizar tokens progresivos. Objetivo: bajar
   latencia percibida de ~4-6s a ~1-2s (que el interlocutor remoto no note
   espera — "es time-critical").
7. **Modo debug**: toggle ON/OFF (default OFF), en vivos muestra latencia
   VAD→whisper→IA por etapa, tokens usados, modelo, response raw/reasoning si el
   modelo lo permite; guarda métricas por sesión (JSON/CSV) para benchmark.

### Decisiones CERRADAS (confirmadas por el usuario, 2026-09-11)
- **Nombre de la app: "Atril"** ✅ — para branding, rename visible del plugin,
  y el ASCII art cuando exista la TUI.
- **Captions: mantener fin-de-frase** ✅ — se conserva el comportamiento actual
  (~0.7s tras callar); NO se exploran parciales/ASR streaming. Ver §6 para la
  justificación técnica.

## 4. Línea base actual (revisar antes de tocar)

- Fases 1-6 ✅, Fase 7 a medias. Bugs abiertos: **B01** (primera frase perdida,
  Alta), **B02** (alucinación "Gracias." en silencio, Alta), B03 (anti-sidetone
  pendiente de validar en vivo), B04 (frase corrupta al cierre), B05 (feed
  arrastra texto viejo, mitigado), B06 (latencia push-to-ask), B07-B08 menores.
- **1 commit local sin push** (`fd0c02d`). ⇒ Primer paso en OpenCode: push.
- Verificar que el plugin instalado en
  `~/.config/DankMaterialShell/plugins/voxtypeOverlay/` es **symlink** al repo
  (OpenCode afirma que sí; confirmar con `ls -l`) — si es copia, los cambios QML
  no hot-reload.
- `chat_completion_stream` no implementado (bloquea streaming).
- `kb_index.py` = embeddings locales (sentence-transformers+torch) — candidato a
  ser REEMPLAZADO por OpenNotebook cuando la integración esté lista.

## 5. Fases del roadmap (ordenadas por prioridad del usuario)

### Sprint 0 — Estabilización (prerequisito, corto)
- [ ] `git push` del commit pendiente (`fd0c02d`).
- [ ] Confirmar symlink del plugin instalado; si es copia, migrar.
- [ ] Fix **B01** (primera frase perdida): pre-arrancar `LiveCapture` en idle al
      abrir el panel del auditor, o esperar a que los `pw-record` estén activos.
- [ ] Fix **B02** (alucinación "Gracias."): subir `vad_threshold` (~0.010-0.015),
      exigir mínimo de energía sostenida + frase ~500ms, y/o arrancar
      `whisper-server` con `-sns` y `-nth 0.8`; opcional filtro post-transcripción
      contra lista de alucinaciones conocidas.

### Sprint 1 — Prioridad ALTA ("lo primero", habilita UX y benchmarking)
- [ ] **Modo debug** (toggle, default OFF): métricas por etapa
      (VAD→whisper→IA), latencia total, tokens, modelo; guardado JSON/CSV por
      sesión; mostrar reasoning/response raw cuando el modelo lo permita.
- [ ] **Botón "Sugerir"** (renombra "Preguntar"): single-click, sin mantener
      presionado. Toma transcripción reciente + contexto y llama a la IA.
      Eliminar el flujo de pulsación larga (ScrollLock en modo reunión deja de
      ser push-to-hold; pasa a trigger de sugerencia).
- [ ] **Streaming de IA**: implementar `chat_completion_stream` y renderizar
      tokens progresivos en el feed (estado "💭 pensando…" → token a token).
      Objetivo latencia percibida ≤~2s.
      **Spec técnica completa**: `docs/STREAMING-IA-SPEC.md` (7 secciones:
      flujo actual, cambios en omniroute_client.py, auditor.py,
      AuditorThread.qml, OverlayWindow.qml, testing plan, riesgos).
- [ ] **Verbosidad del transcript**: selector Corto/Medio/Detallado en Settings;
      prompt distinto según nivel (Corto = resumen ≤10 palabras sin IA extra).

### Sprint 2 — Integración OpenNotebook (ALTA)
- [ ] Settings → OpenNotebook: URL del servidor + botón "Probar conexión" +
      selector de notebook (`GET /api/notebooks`).
- [ ] Toggle "Usar OpenNotebook" (default ON si disponible; fallback a
      `kb_index.py` o a IA bruta si no).
- [ ] `opennotebook_client.py`: cliente HTTP async para `/api/search` y
      `/api/ask` (scoped por `notebook_id`), compatible con la API REST real.
- [ ] Mostrar la FUENTE de cada respuesta en el feed: 📚 OpenNotebook:[notebook]
      vs 💡 IA bruta (transparencia de procedencia).
- [ ] Doc: setup de OpenNotebook (Docker; en PC ahora, OPI luego).

### Sprint 3 — Prioridad MEDIA
- [ ] **Config de modelo Whisper**: selector en Settings (small/medium/large-v3/
      large-v3-turbo + VRAM estimada); restart de whisper-server al cambiar.
- [ ] **Benchmark periódico de IA + fallback**: health check cada N min
      (configurable) usando el modelo de la tarea activa; si falla/tarda →
      fallback automático (cadena: OmniRoute primario → local-pequeño → aviso).
      Indicador de salud en el pill de la barra.
- [ ] **Summarize periódico + botón "Recap"**: buffer de últimas N frases, al
      superar umbral llama a IA para resumen parcial; botón "📋 Recap" en el
      panel muestra el último resumen (ícono distinto en feed).
- [ ] **Indetectable a screen-share**: verificar con captura (`grim`/`wf-recorder`)
      que el overlay layer-shell NO aparece al compartir pantalla; documentar.

### Sprint 4 — Prioridad BAJA
- [ ] **Post-reunión**: recap final + "puntos a mejorar" + fuentes de estudio
      (link a notebooks si OpenNotebook activo) + sugerencia de agregar fuente;
      volcado a Obsidian (reusar `voxtype-export-mtg`).
- [ ] **Modo "Preparar reunión"**: sub-daemon `prep` (vs `capture`); la IA
      entrevista al usuario desde el notebook seleccionado (su CV/vault); feed de
      prep (pregunta IA ↔ respuesta voz ↔ feedback); recap de debilidades.
- [ ] **Reorganizar Settings en acordeones**: Daemon, Audio, IA, OpenNotebook,
      Whisper, Debug (prerequisito para la UI final con todas las opciones).
- [ ] **Selector de timeline** en el feed (slider con timestamps de frases).
- [ ] **Contexto visual** (screen): captura de pantalla + contexto a la IA
      (en Wayland es lo más complejo; requiere grim/sharing, baja prioridad).

### Sprint 5 — Muy baja / futuro
- [ ] **Detección en vivo de fallos de datos** (experimental, default OFF).
- [ ] **ASCII art con el nuevo nombre** cuando exista la TUI.
- [ ] Migrar OpenNotebook al OPI (Armbian + NPU) cuando esté listo.

## 6. Tema abierto de arquitectura: captions parciales vs fin-de-frase

Estado: sin streaming de ASR. `whisper-server` transcribe por frase completa
(batch), por eso el texto llega recién ~0.7s tras dejar de hablar, no de forma
continua. Cluely muestra parciales cada ~300ms porque usa ASR streaming.

- **(a) Mantener fin-de-frase** (RECOMENDADO): calidad punta, coherente con la
  decisión Fase 6 (se descartó parakeet/nemotron streaming). La latencia
  percibida en conversación normal es similar al "fin de frase" de los demás.
- **(b) Flush parcial** cada ~2-3s en frases largas: re-transcribir ventana
  reciente con whisper no-streaming — caro y tembloroso.
- **(c) Motor ASR streaming solo para parciales** + whisper para la frase final:
  contradictorio con Fase 6 y añade un modelo nuevo.

Pendiente: confirmar con el usuario antes de tocar `audio_capture.py`/`auditor.py`.

## 7. Pregunta abierta del plan

**¿Un modelo local puede responder más rápido que uno online?**
Sí, para respuestas cortas (~1.5-3s en RX 6650 XT con un 3B Q4 vs 3.5s de
OmniRoute), pero con menos calidad de RAG y presión de VRAM (comparte con
whisper-server 1.6GB + compositor). Conclusión: streaming online ya; local-pequeño
como fallback futuro (sinergia con #10 / OPI-NPU).

## 8. Gaps, detalle de features, y evaluación de cada idea

> Notas de la sesión de trazado (2026-09-11) que completan el roadmap.
> Incluye funcionalidades que quedaron sueltas y la evaluación que el usuario
> pidió ("qué tal cada idea, limitaciones e impacto").

---

### G1 — Sandbox de prueba pre-reunión (Sprint 4, junto al modo Prep)

**Qué es:** antes de entrar a una reunión real, un modo donde puedes probar
cómo funciona todo: la IA responde a una pregunta ficticia con el notebook
seleccionado, puedes ver si el streaming funciona, si la fuente se muestra
correctamente, y si la transcripción está limpia. Es un "dry run".

**Dónde va:** dentro del Sprint 4 (modo "Preparar reunión"). Es el paso
cero antes de cualquier ensayo real: validar que todo está conectado.

**Limitación:** solo es útil si OpenNotebook ya está configurado (Sprint 2).
Si no, el sandbox testearía contra IA bruta y no probaría la integración real.

**Cómo implementarlo:**
- Botón "🧪 Probar sistema" en Settings o en el panel del auditor
- Ejecuta 3 pasos secuenciales: (1) health check OpenNotebook → (2) pregunta
  de prueba al notebook → (3) captura 5s de mic → transcripción de prueba
- Muestra los 3 resultados con ✓/✗ en el feed
- Incluible en el modo Prep como "checklist antes de la reunión"

---

### G2 — Análisis de eficiencia del proyecto actual

*Respuesta de Hermes en la sesión de trazado, consolidada aquí para OpenCode.*

#### Qué funciona bien
| Componente | Por qué funciona |
|---|---|
| Arquitectura event-driven (JSONL) | Acoplamiento loose entre Python y QML — cada mitad evoluciona independiente |
| VAD por fin-de-frase (no chunks fijos) | Latencia percibida mejor: texto llega cuando paras de hablar, no cada 2s |
| Anti-sidetone con regla temporal | Solución elegante al problema BT HFP — sin dedupe textual frágil |
| PID-unique WAVs + orphan killer | Robustez ante crashes — pw-record no corrompe la sesión |
| whisper-server persistente (Vulkan) | 400-660ms por frase en GPU, sin recargar modelo en cada invocación |

#### Qué necesita trabajo (deuda técnica)
| Qué | Por qué es deuda | Impacto |
|---|---|---|
| `chat_completion_stream` lanza `NotImplementedError` | Streaming IA no existe → latencia 4-6s por respuesta | **Bloqueante para sprint 1** |
| `kb_index.py` (sentence-transformers + torch) | Embeddings locales pesados, 1-2GB RAM, innecesarios cuando OpenNotebook esté listo | Reemplazable en sprint 2 |
| Plugin instalado como copia (no symlink) | Cada cambio QML requiere copia manual + reload de DMS | Friction en desarrollo |
| Sin persistencia de métricas | No hay benchmarking, no hay datos de latencia reales | Bloqueante para sprint 1 (modo debug) |
| Sin streaming ASR | Captions llegan ~0.7s tras callar (fin-de-frase), no parciales | **Decisión aceptada** — mantener fin-de-frase |

#### Eficiencia del pipeline actual
| Paso | Latencia actual | Objetivo |
|---|---|---|
| VAD (detectar fin de frase) | ~0.8s silencio sostenido | ✅ OK |
| whisper-server (transcribir) | 400-660ms | ✅ OK |
| IA OmniRoute (responder) | 3.5s (sin streaming) | ≤2s con streaming (sprint 1) |
| **Total caption-only** | **~0.7-1.4s tras callar** | ✅ |
| **Total con IA** | **~4-5s tras callar** | ≤2s con streaming |

---

### G3 — Feature "Follow-up questions" (de Cluely) + evaluación de cada idea

#### Follow-up questions

En Cluely, tras cada respuesta de la IA, aparecen 2-3 "preguntas de
seguimiento" sugeridas — cosas que podrías preguntar basándose en lo que
acaba de decir la otra persona.

**Dónde va:** Sprint 3 (junto al Recap). Cuando la IA responde a un
"Sugerir", ofrece 2-3 follow-ups como chips clickeables en el feed. Clic
en un chip = nueva pregunta a la IA con ese contexto.

**Limitación:** latencia adicional (~1s por chips generados). Mitigar:
generar los follow-ups como parte de la misma llamada de "Sugerir" (prompt
modificado: "responde + sugiere 2-3 preguntas de seguimiento relevantes").

---

#### Mini-evaluación de cada idea del usuario

| # | Idea | Veredicto | Impacto | Limitación principal |
|---|------|-----------|---------|---------------------|
| 1 | Verbosidad Corto/Medio/Detallado | ✅ Excelente, bajo riesgo | Alto — legibilidad en reuniones largas | Prompt distinto por nivel, sin llamados IA extra si se hace como parte de la transcripción |
| 2+6 | OpenNotebook vía REST + selector | ✅ Excelente, pieza central | Muy alto — reemplaza kb_index.py, RAG serio | Requiere Docker (SurrealDB+FastAPI), 1-1.5GB RAM. HTTP call por query vs embeddings locales |
| 3 | Modo Prep (IA entrevista desde notebook) | ✅ Brillante, es un producto nuevo dentro del producto | Muy alto — diferenciador vs Cluely/FinalRound | Modo daemon distinto (prep vs capture), panel QML dinámico |
| 4 | UI en acordeones | ✅ Necesario, prerequisite | Medio — prerequisite para las 15+ opciones nuevas | Solo trabajo QML, sin bloqueos técnicos |
| 5 | Selector de timeline | ✅ Bueno, slider simple | Medio — en reuniones largas es oro; en cortas no aporta mucho | No bloqueante para nada |
| 7 | Modo debug | ✅ Esencial para desarrollo | Alto para dev, medio para usuario final | Toggle OFF por defecto, sin overhead cuando está apagado |
| 8b | Invisible a screen-share | ✅ Ya está resuelto por el stack | Medio — verificar nomás | Wayland layer-shell: overlays no aparecen en capturas por diseño |
| 8c | Botón "Sugerir" (single-click) | ✅ Excelente — cambia el paradigma | Alto — UX inmediata | Eliminar comportamiento de ScrollLock hold; cleanup de event handlers |
| 9 | Config modelo Whisper | ✅ Simple y necesario | Medio — usuarios avanzados lo necesitan | Restart de whisper-server al cambiar; default puede ser auto |
| 10 | Benchmark IA periódico + fallback | ✅ Muy inteligente | Alto — previene dead air en reuniones | Health check puede no detectar si el modelo de prueba OK y el real falla |
| 11 | Summarize + Recap | ✅ Excelente | Muy alto — en reuniones largas el recap es lo más valioso | Un llamado IA extra cada N frases (~3.5s, bajo costo con OmniRoute) |
| 12 | Detección live de fallos de datos | ⚠️ Experimental, interesante | Bajo-médio — útil en contextos numéricos/fácticos | Alta latencia adicional (~5-8s), falsos positivos, solo útil en dominios específicos |
| 13 | ASCII art con nuevo nombre | ✅ Fácil, branding | Bajo — pero BUILDABLE como task de opening | Necesita que la TUI exista primero |
| 15 | Post-reunión (recap+mejorar+fuentes) | ✅ El cierre perfecto — ciclo completo | Muy alto — cierra el loop de aprendizaje continuo | Requiere notebook configurado en OpenNotebook para máximo valor |
| 16 | 100% open/local/gratis | ✅ La propuesta de valor fundamental | Diferenciador vs Cluely/FinalRound (ambos cloud, $20-75/mes) | Solo Linux Wayland por ahora (sin Mac/Windows) |

---

### Cluely: feature matching para Atril

Funcionalidades de Cluely (sitio web, 2026) que Atril puede replicar o superar:

| Cluely feature | Atril equivalente | Sprint | Notas |
|---|---|---|---|
| Invisible to screen share | ✅ Ya por layer-shell Wayland | Verificar Sprint 3 | Atril ya lo tiene "gratis" por el stack |
| "What should I say" (one-click) | ✅ "Sugerir" — single-click, same concept | Sprint 1 | Renombrada + mejorada: usa contexto del notebook |
| Follow-up questions | ✅ Chips clickeables post-respuesta | Sprint 3 | Cluely los muestra; Atril los genera como parte de la misma llamada |
| Recap (post-meeting) | ✅ Recap final + puntos a mejorar | Sprint 4 | Atril va más lejos: fuentes de estudio + auto-sugerir agregar al notebook |
| Viewed screen (contexto visual) | ⚠️ Pendiente (baja prioridad) | Sprint 4 | En Wayland requiere grim/sharing; no es bloqueante |
| Doesn't join meetings | ✅ Atril nunca se conecta a la sala | Diseño base | Escucha audio del sistema, no se registra como participante |
| Meeting notes (instant) | ✅ Feed en vivo + export a Obsidian | Base + Sprint 4 | Atril exporta a tu vault directamente |

**Lo que Atril hace que Cluely NO hace:**
- RAG sobre conocimiento propio (vault/OpenNotebook) — Cluely genera de contexto genérico
- Benchmark de IA + fallback automático
- Modo prep con tu propio CV/notebook
- Post-reunión con fuentes de estudio + auto-sugerir agregar a notebook
- Verbosidad configurable
- 100% local y gratis

---
