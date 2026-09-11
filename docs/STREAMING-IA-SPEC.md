# Streaming de IA — Especificación técnica para OpenCode

> **Objetivo**: reducir la latencia percibida de respuesta IA de ~4-6s a ≤~2s
> mediante streaming SSE + renderizado progresivo de tokens en el feed.
> **Archivo de referencia**: `docs/ROADMAP-FEATURES.md` — Sprint 1.
> **Estado de implementación (2026-09-11)**: implementado y pendiente de prueba
> en vivo. Las secciones siguientes conservan el diseño inicial; donde difieran,
> la implementación vigente es:
>
> - `chat_completion(stream=True)` sigue rechazado; el streaming usa el
>   generador explícito `chat_completion_stream`.
> - Los eventos usan `request_id` de la solicitud explícita, no un `stream_id`
>   separado.
> - Los deltas se agrupan en Python (primero inmediato, luego cada 75 ms o 64
>   caracteres).
> - QML conserva texto parcial por `request_id` y una revisión de repintado, en
>   lugar de reemplazar todo el arreglo por token o de usar índices fijos.
> - `ai_stream_done`/`ai_stream_error` se convierten en la única entrada final;
>   el fallback sin tokens emite `ai_stream_done` y no duplica la respuesta.
> - La respuesta parcial interrumpida se guarda como `ai_error` con `partial` e
>   `incomplete`, sin crear además una respuesta completa distinta.
> - El timeout de seguridad de “Sugerir” es 65 s para cubrir el timeout total
>   del stream.

---

## 0. Flujo actual (sin streaming)

```
Usuario presiona "Sugerir"
  → auditor.py: _end_ask_rag()          [línea 572]
    → self.ai.chat_completion(...)       [línea 622] ← BLOQUEA ~3.5s
    → evento: {"type":"ai_answer", "answer":"respuesta completa"}
  → AuditorThread._handleLine()         [línea 123]
    → _enqueue(evt)                     [línea 143]
  → OverlayWindow delegate              [línea 545]
    → StyledText: e.answer              [línea 614]
```

**Problema**: el usuario ve "💭 pensando…" y luego ~3.5s después aparece la
respuesta completa de golpe. El interlocutor remoto percibe silencio.

---

## 1. Cambios en `audit/omniroute_client.py`

### 1.1 — `chat_completion` (línea 147): no redirigir `stream=True`

> Implementación vigente: `chat_completion(stream=True)` sigue lanzando
> `NotImplementedError`. La ruta de streaming llama directamente al generador
> explícito `chat_completion_stream`.


No se aplica el reemplazo anterior. La implementación vigente conserva el
contrato sincrónico y usa directamente `chat_completion_stream(..., stats=...)`.

### 1.2 — `chat_completion_stream`: implementación vigente

El generador ya maneja SSE robusto, `stream_options.include_usage` con
fallback, reintentos previos al primer token, timeouts de primer token,
inactividad y total, y telemetría en `stats`. El fragmento siguiente era el
diseño inicial y no debe aplicarse tal cual.
```python
async def chat_completion_stream(self, messages, task="kb_fallback",
                                  temperature=None, max_tokens=None):
    """Generator async que yield chunks de texto. Maneja 429/500."""
    model_cfg = self.config.get_model(task)
    payload = {
        "model": model_cfg.name,
        "messages": messages,
        "temperature": temperature if temperature is not None else model_cfg.temperature,
        "max_tokens": max_tokens or model_cfg.max_tokens,
        "stream": True,
    }

    last_err = None
    for attempt in range(self.config.max_retries + 1):
        try:
            async with self.session.post(
                self._endpoint(), json=payload
            ) as resp:
                if resp.status == 429:
                    retry_after = int(resp.headers.get("Retry-After", "2"))
                    await asyncio.sleep(retry_after)
                    continue
                if resp.status >= 500:
                    raise aiohttp.ClientResponseError(
                        request_info=resp.request_info,
                        history=resp.history,
                        status=resp.status,
                        message=f"Server error {resp.status}")
                async for raw_line in resp.content:
                    line = raw_line.decode("utf-8").strip()
                    if not line.startswith("data: "):
                        continue
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        return
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk["choices"][0]["delta"]
                        if "content" in delta:
                            yield delta["content"]
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
                return  # stream completo
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            last_err = e
            if attempt < self.config.max_retries:
                await asyncio.sleep(self.config.retry_delay * (2 ** attempt))
            else:
                raise
```

---

## 2. Cambios en `audit/auditor.py`

### 2.1 — Nuevo tipo de evento JSONL: `ai_stream`

Agregar al bloque de emit del helper (cerca de línea 35):
```python
# Tipos soportados:
# {"type":"enunciado","speaker":"you|remote",...}
# {"type":"kb_hit","speaker":"you",...}
# {"type":"ai_answer","speaker":"you","answer":"..."}
# {"type":"ai_stream","speaker":"you","delta":"token parcial","stream_id":"<uuid>"}
# {"type":"ai_stream_done","speaker":"you","answer":"respuesta completa","stream_id":"<uuid>"}
# {"type":"ai_error","speaker":"you",...}
# {"type":"info",...}
```

> Implementación vigente: los eventos usan `request_id` de la solicitud
> explícita y deltas por lotes (`ai_stream_delta`), no un `stream_id`
> separado ni un delta por token. El único registro persistente es el evento
> final convertido; los parciales no se guardan en la sesión.

### 2.2 — Método `_ai_answer_stream` en `MeetingAuditor` (implementación vigente)

El método comparte el constructor de prompts con `_ai_answer`, emite lotes y
usa `request_id`.

Diseño inicial conservado abajo como referencia:

Agregar después de `_ai_answer` (línea 208):

```python
async def _ai_answer_stream(self, side: str, text: str,
                             results: List[Dict], emit) -> str:
    """Versión streaming de _ai_answer. Emite chunks parciales."""
    import uuid
    stream_id = str(uuid.uuid4())[:8]

    # Construir messages (mismo prompt que _ai_answer, copy-paste de líneas 209-263)
    convo = self._conversation_block(max_items=6)
    who = "Tú" if side == "you" else "Remoto"
    if results:
        chunks = "\n".join(
            f"[{r['score']:.2f}] {r['file_path']}: {r['content'][:400]}"
            for r in results[:4])
        system = (...)  # mismo prompt que _ai_answer
        user = (f"Contexto de la reunión:\n{convo}\n\n"
                f"{who}: \"{text}\"\n\n"
                f"Notas del vault:\n{chunks}\n\n"
                "Respuesta (si las notas no sirven, ignóralas):")
    else:
        # ... mismo prompt que _ai_answer para vault ON/OFF ...

    messages = [{"role": "system", "content": system},
                {"role": "user", "content": user}]

    full_answer = ""
    try:
        async for chunk in self.ai.chat_completion_stream(
                messages, task="kb_fallback", temperature=0.2, max_tokens=500):
            full_answer += chunk
            emit({
                "type": "ai_stream",
                "speaker": side,
                "delta": chunk,
                "stream_id": stream_id,
            })
    except Exception as e:
        log.error(f"_ai_answer_stream error: {e}")
        emit({"type": "ai_error", "speaker": side, "msg": str(e)[:200]})
        return ""

    emit({
        "type": "ai_stream_done",
        "speaker": side,
        "answer": full_answer,
        "stream_id": stream_id,
    })
    return full_answer
```

### 2.3 — `_answer_suggest_question` usa streaming (implementación vigente)

`_end_ask_rag` ya no existe. La solicitud explícita llama a
`_answer_suggest_question`, que invoca `_ai_answer_stream` y conserva una sola
entrada final en `session_log`. No se emite una terminal duplicada junto a
`ai_stream_done`.

Diseño inicial conservado abajo como referencia:

En `_end_ask_rag` (línea 572), reemplazar la llamada a `_ai_answer`:

```python
# Línea 622: REEMPLAZAR
answer = await self._ai_answer("you", ask_text, results)

# POR:
answer = await self._ai_answer_stream("you", ask_text, results, emit)
```

El resto de la lógica (emit de `kb_hit` o `ai_answer` como fallback) se
mantiene. El `ai_stream_done` reemplaza al `ai_answer` al final del
streaming, pero como redundancia se emite `ai_answer` con la respuesta
completa para que el feed tenga el evento final limpio.

### 2.4 — La función `_process_with_ai` (opcional, Phase 2)

Si se quiere streaming también para RAG automático (cuando esté activado),
aplicar el mismo patrón. Para Sprint 1 solo `_end_ask_rag` usa streaming.

---

## 3. Implementación vigente en `auditor_components/AuditorThread.qml`

Los fragmentos siguientes eran el diseño inicial. La implementación conserva
`ai_streaming`, pero usa `request_id`, un mapa de texto parcial y una revisión
de repintado; no usa índices fijos ni reemplaza todo el arreglo por token.

### 3.1 — Manejar evento `ai_stream` en `_handleLine`

En `_handleLine` (línea 123), antes de `_enqueue`, detectar `ai_stream`:

```javascript
function _handleLine(line) {
    const s = (line || "").trim();
    if (s === "") return;
    let evt;
    try { evt = JSON.parse(s); } catch (e) { return; }
    if (!evt || typeof evt !== "object") return;
    if (root.status === "starting") root.status = "running";

    root.eventReceived(evt);

    // ── Streaming IA: append incremental al último evento ──
    if (evt.type === "ai_stream" && evt.stream_id) {
        _appendStreamDelta(evt);
        return;  // NO llamar _enqueue — se acumula en el evento padre
    }
    if (evt.type === "ai_stream_done" && evt.stream_id) {
        _finalizeStream(evt);
        return;
    }

    root._enqueue(evt);
}
```

### 3.2 — Buffer de streaming

Agregar propiedades y funciones al componente:

```javascript
property var _streamBuffer: ({})  // stream_id → {index, text}

function _appendStreamDelta(evt) {
    const sid = evt.stream_id;
    if (!_streamBuffer[sid]) {
        // Primera vez: crear un evento placeholder en el feed
        const placeholder = {
            type: "ai_streaming",  // tipo transitorio
            speaker: evt.speaker,
            text: "",              // vacío, se llena incrementalmente
            stream_id: sid,
            ts: evt.ts || ""
        };
        const idx = root.events.length;
        root.events = root.events.concat([placeholder]);
        _streamBuffer[sid] = { index: idx, text: "" };
    }
    const buf = _streamBuffer[sid];
    buf.text += evt.delta;
    // Actualizar el evento en el array (trigger de re-render)
    const events = root.events.slice();
    events[buf.index] = { ...events[buf.index], text: buf.text };
    root.events = events;
}

function _finalizeStream(evt) {
    const sid = evt.stream_id;
    if (_streamBuffer[sid]) {
        const buf = _streamBuffer[sid];
        const events = root.events.slice();
        // Convertir de "ai_streaming" a "ai_answer" definitivo
        events[buf.index] = {
            ...events[buf.index],
            type: "ai_answer",    // tipo final → el delegate lo pinta con 💡
            answer: evt.answer,   // respuesta completa
            text: events[buf.index].text  // texto parcial acumulado
        };
        root.events = events;
    }
    delete _streamBuffer[sid];
}
```

### 3.3 — Variable `events` debe trigger re-render en streaming

El array `events` ya se reemplaza por completo (`root.events = events`)
en `_appendStreamDelta`. El `ListView` ya reacciona a cambios en el
modelo porque `model: win.auditor.events` se re-evalúa.

**No se necesita** `incrementalModelChanges` porque QML ListView re-crea
delegates al detectar cambio en el array referenciado por `model`.

---

## 4. Cambios en `OverlayWindow.qml`

### 4.1 — Delegate: manejar tipo `ai_streaming` (transitorio)

En el delegate (línea 545), agregar handling para `ai_streaming`:

```javascript
// StyledText para answer (línea 611-618): REEMPLAZAR
StyledText {
    width: parent.width
    visible: e.type === "kb_hit" || e.type === "ai_answer" || e.type === "ai_streaming"
    text: (e.type === "kb_hit" ? "📚 " : "💡 ") + (e.answer || "")
    font.pixelSize: 14
    color: (e.type === "kb_hit") ? Qt.rgba(0.35, 0.8, 0.5, 1)
         : Qt.rgba(0.45, 0.7, 1, 1)
    wrapMode: Text.WordWrap
}
```

### 4.2 — Indicador de streaming activo

Cuando el evento es `ai_streaming`, mostrar cursor de escritura o ícono
pulsante:

```javascript
// Nuevo: indicador de streaming después del answer text
StyledText {
    width: parent.width
    visible: e.type === "ai_streaming"
    text: "▍"  // cursor de escritura
    font.pixelSize: 14
    color: Qt.rgba(0.45, 0.7, 1, 1)
    SequentialAnimation on opacity {
        loops: Animation.Infinite
        PropertyAnimation { from: 1.0; to: 0.3; duration: 500 }
        PropertyAnimation { from: 0.3; to: 1.0; duration: 500 }
    }
}
```

### 4.3 — Auto-scroll durante streaming (implementación vigente)

El crecimiento del texto parcial cambia la altura del delegate y conserva el
comportamiento del switch existente: con auto-scroll ON baja al final; con OFF
no mueve la vista.

Diseño inicial conservado abajo como referencia:

Ya existe `onCountChanged: Qt.callLater(scrollToBottom)` (línea 539-541).
Con el streaming, `root.events` se actualiza por cada delta → el
`onCountChanged` se dispara una vez (al crear el placeholder) y luego
`onDataChanged` del array dispara re-render. Agregar:

> Implementación vigente: no se usa `onDataChanged`, que no existe como señal
> útil del `ListView` para este caso. El delegate se repinta mediante
> `streamTexts` + `streamRevision`; `onContentHeightChanged` conserva el
> auto-scroll cuando está activado.

---

## 5. Flujo final implementado

```
Usuario presiona "Sugerir"
  → auditor.py: _answer_suggest_question()
    → _ai_answer_stream("you", ask_text, results, request_id, emit, telemetry)
      → self.ai.chat_completion_stream(messages, stats=stats)   ← async generator
        → primer token en ~300-500ms
          → emit({"type":"ai_stream_delta","delta":"El","request_id":"a1b2"})
          → emit({"type":"ai_stream_delta","delta":" resultado","request_id":"a1b2"})
          → emit({"type":"ai_stream_delta","delta":" es...","request_id":"a1b2"})
          ...
          → emit({"type":"ai_stream_done","answer":"El resultado es...","request_id":"a1b2"})
  → AuditorThread._handleLine()
    → mapa de texto parcial por `request_id` + placeholder `ai_streaming`
    → convierte `ai_stream_done` en la única entrada final
  → OverlayWindow delegate
    → ve "El resultado es..." creciendo por lotes
    → cursor durante el streaming
    → respuesta completa al final con 💡 o 📚
```

**Latencia percibida**: primer token a ~500ms (vs ~3.5s actual).
**Latencia total**: la misma (~3.5s), pero el usuario la ve creciendo.

---

## 6. Testing plan

1. **Unit test de `chat_completion_stream`**: mock de aiohttp, simular
   chunks SSE, verificar que yieldea texto correctamente.
2. **Test de `_ai_answer_stream`**: mock de `chat_completion_stream`,
   verificar que emite eventos `ai_stream` + `ai_stream_done`.
3. **Test visual**: reunión real corta (30s), presionar "Sugerir",
   verificar que el texto aparece token a token en el feed.
4. **Benchmark**: en modo debug, medir latencia del primer token
   (debería ser <500ms con OmniRoute `auto/best-chat`).

---

## 7. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| OmniRoute no soporta SSE | OmniRoute es OpenAI-compatible v1 → SSE es parte del estándar; si falla, fallback a sync con warning |
| QML ListView no reacciona a cambios en array | Ya funciona para `ai_answer` existente; `_appendStreamDelta` reemplaza el array completo por evento |
| Tokens parciales llegan cortados (mitad de palabra) | No importa: el renderizado es continuo, la palabra se completa con el siguiente chunk |
| Timeout en streaming (responde lento) | Timeouts explícitos de primer token (10 s), inactividad (15 s) y total (60 s); sin tokens usa fallback sincrónico; con texto parcial emite `ai_stream_error` y conserva el parcial marcado como incompleto |
| Usuario hace clic en "Sugerir" múltiples veces | El `request_id` de la solicitud explícita diferencia sesiones; cada stream actualiza solo su placeholder |

---

## 8. Pendiente próxima sesión: micro-saltos del render

Ver `docs/BUGS-AUDITOR.md` §B11. Ya no se reemplaza el modelo por cada delta:
los deltas actualizan `streamTexts` + `streamRevision`, el placeholder se crea o
finaliza una sola vez, y el auto-scroll usa una llamada diferida con animación
de 120 ms solo cuando está activado.

Queda por instrumentar `contentY`, `contentHeight`, `count` y timestamps durante
un stream real, comparar auto-scroll ON/OFF y respuestas cortas/largas, y
evaluar un anclaje de cola coalescido por frame o un modelo dedicado a la fila
activa. No cambiar de modelo/proveedor en ese paso.
