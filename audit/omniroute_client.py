#!/usr/bin/env python3
"""
omniroute_client.py — Cliente para OmniRoute / OpenAI-compatible API.
Soporta múltiples proveedores con endpoint/base_url + API key.
Configurable: modelos/combos por tipo de tarea.
"""

import os
import codecs
import json
import asyncio
import aiohttp
import time
from typing import Dict, List, Optional, Any, Literal
from dataclasses import dataclass, field, asdict
from pathlib import Path
import yaml


# Streaming de IA: timeouts aprobados por el roadmap.
STREAM_FIRST_TOKEN_TIMEOUT = 10.0
STREAM_STALL_TIMEOUT = 15.0
STREAM_TOTAL_TIMEOUT = 60.0


@dataclass
class ModelConfig:
    """Config de un modelo individual."""
    name: str                          # nombre interno (p.ej. "gpt-4o-mini")
    display_name: str                  # nombre legible
    provider: Literal["omniroute", "openai", "custom"] = "omniroute"
    max_tokens: int = 4096
    temperature: float = 0.3
    # Para combos: qué tareas usa este modelo
    tasks: List[str] = field(default_factory=list)  # ["kb_fallback", "summarize", "reasoning"]


@dataclass
class OmniRouteConfig:
    """Configuración completa del cliente."""
    # Endpoint base (OmniRoute u OpenAI-compatible)
    base_url: str = "https://api.omniroute.ai/v1"
    api_key: str = ""
    # Modelos disponibles
    models: Dict[str, ModelConfig] = field(default_factory=dict)
    # Combo por defecto por tarea
    default_models: Dict[str, str] = field(default_factory=lambda: {
        "kb_fallback": "gpt-4o-mini",
        "reasoning": "gpt-4o",
        "summarize": "gpt-4o-mini",
        "quick": "gpt-4o-mini",
    })
    # Timeouts
    timeout: int = 60
    max_retries: int = 3
    retry_delay: float = 1.0

    @classmethod
    def from_yaml(cls, path: str) -> "OmniRouteConfig":
        with open(path, "r") as f:
            data = yaml.safe_load(f) or {}
        models = {}
        for m in data.get("models", []):
            mc = ModelConfig(**m)
            models[mc.name] = mc
        cfg = cls(
            base_url=data.get("base_url", "https://api.omniroute.ai/v1"),
            api_key=data.get("api_key", os.environ.get("OMNIROUTE_API_KEY", "")),
            models=models,
            default_models=data.get("default_models", {}),
            timeout=data.get("timeout", 60),
            max_retries=data.get("max_retries", 3),
            retry_delay=data.get("retry_delay", 1.0),
        )
        return cfg

    def get_model(self, task: str) -> ModelConfig:
        """Obtiene el ModelConfig para una tarea."""
        model_name = self.default_models.get(task)
        if model_name and model_name in self.models:
            return self.models[model_name]
        # Fallback al primero disponible
        if self.models:
            return list(self.models.values())[0]
        # Sin catálogo (config por env/YAML minimal): usar el nombre del
        # default_models de la tarea (respeta OMNIROUTE_MODEL_KB, auto/best-chat,
        # etc.) en vez del "gpt-4o-mini" hardcodeado que rompía el ASK (el router
        # no tenía credenciales openai).
        name = self.default_models.get(task, "gpt-4o-mini")
        return ModelConfig(name=name, display_name=name, tasks=[task])


class OmniRouteClient:
    """
    Cliente async para OmniRoute / OpenAI-compatible.
    Reintentos, timeouts, logging.
    """

    def __init__(self, config: OmniRouteConfig):
        self.config = config
        self._session: Optional[aiohttp.ClientSession] = None

    async def __aenter__(self):
        timeout = aiohttp.ClientTimeout(total=self.config.timeout)
        self._session = aiohttp.ClientSession(
            timeout=timeout,
            headers={
                "Authorization": f"Bearer {self.config.api_key}",
                "Content-Type": "application/json",
            }
        )
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self._session:
            await self._session.close()

    @property
    def session(self) -> aiohttp.ClientSession:
        if self._session is None:
            raise RuntimeError("Session not initialized. Use async context manager.")
        return self._session

    def _endpoint(self, path: str = "/chat/completions") -> str:
        base = self.config.base_url.rstrip("/")
        return f"{base}{path}"

    async def _request_with_retry(self, payload: Dict) -> Dict:
        """POST con reintentos exponenciales."""
        last_err = None
        for attempt in range(self.config.max_retries + 1):
            try:
                async with self._session.post(self._endpoint(), json=payload) as resp:
                    if resp.status == 429:  # rate limit
                        retry_after = int(resp.headers.get("Retry-After", "2"))
                        await asyncio.sleep(retry_after)
                        continue
                    if resp.status >= 500:
                        raise aiohttp.ClientResponseError(
                            request_info=resp.request_info,
                            history=resp.history,
                            status=resp.status,
                            message=f"Server error {resp.status}"
                        )
                    return await resp.json()
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                last_err = e
                if attempt < self.config.max_retries:
                    await asyncio.sleep(self.config.retry_delay * (2 ** attempt))
                else:
                    raise
        raise last_err or RuntimeError("Max retries exceeded")

    async def chat_completion(
        self,
        messages: List[Dict[str, str]],
        task: str = "kb_fallback",
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        stream: bool = False,
        capture: Optional[Dict[str, Any]] = None,
    ) -> str:
        """
        Completion no-streaming. Retorna el content del primer choice.

        Si `capture` es un dict, lo llena con telemetría (modelo, uso,
        latencia y respuesta cruda) sin cambiar el valor retornado.
        """
        model_cfg = self.config.get_model(task)
        actual_temperature = temperature if temperature is not None else model_cfg.temperature
        actual_max_tokens = max_tokens or model_cfg.max_tokens
        payload = {
            "model": model_cfg.name,
            "messages": messages,
            "temperature": actual_temperature,
            "max_tokens": actual_max_tokens,
            "stream": stream,
        }
        if stream:
            raise NotImplementedError("Streaming no implementado aún; usar sync")

        started = time.monotonic()
        data = await self._request_with_retry(payload)
        duration_ms = (time.monotonic() - started) * 1000.0
        try:
            choices = data.get("choices", []) if isinstance(data, dict) else []
            message = choices[0].get("message", {}) if choices else {}
            answer = message.get("content", "").strip()
            usage = data.get("usage", {}) if isinstance(data, dict) else {}
            if not isinstance(usage, dict):
                usage = {}
            raw = {
                "model": data.get("model", model_cfg.name) if isinstance(data, dict) else model_cfg.name,
                "finish_reason": choices[0].get("finish_reason") if choices else None,
                "message": message,
                "usage": usage,
            }
            if capture is not None:
                capture.update({
                    "ok": True,
                    "configured_model": model_cfg.name,
                    "response_model": raw["model"],
                    "temperature": actual_temperature,
                    "max_tokens": actual_max_tokens,
                    "prompt_tokens": usage.get("prompt_tokens"),
                    "completion_tokens": usage.get("completion_tokens"),
                    "total_tokens": usage.get("total_tokens"),
                    "duration_ms": round(duration_ms, 1),
                    "answer_chars": len(answer),
                    "raw": json.dumps(raw, ensure_ascii=False),
                })
            if not answer:
                raise RuntimeError(f"Respuesta vacía: {data}")
            return answer
        except (KeyError, IndexError, AttributeError, TypeError):
            if capture is not None:
                capture.update({
                    "ok": False,
                    "configured_model": model_cfg.name,
                    "duration_ms": round(duration_ms, 1),
                    "raw": json.dumps(data, ensure_ascii=False)[:4000],
                })
            raise RuntimeError(f"Respuesta inesperada: {data}")

    @staticmethod
    async def _read_sse_body(resp, telemetry: Dict[str, Any],
                             first_token_timeout: float = STREAM_FIRST_TOKEN_TIMEOUT,
                             stall_timeout: float = STREAM_STALL_TIMEOUT,
                             total_timeout: float = STREAM_TOTAL_TIMEOUT):
        """Lee un cuerpo SSE y produce solo texto nuevo.

        Tolera fragmentos TCP arbitrarios, líneas CRLF, comentarios SSE y
        eventos `data:` multilínea. No reintenta después del primer fragmento.
        Registra el progreso en `telemetry`.
        """
        decoder = codecs.getincrementaldecoder("utf-8")()
        buffer = ""
        data_lines: List[str] = []
        started = time.monotonic()
        last_progress = started

        def elapsed() -> float:
            return time.monotonic() - started

        def check_timeouts() -> None:
            now = time.monotonic()
            if now - started > total_timeout:
                raise TimeoutError(f"stream excedió {total_timeout:.0f}s totales")
            if now - last_progress > stall_timeout:
                raise TimeoutError(f"stream detenido {stall_timeout:.0f}s sin datos")
            if not telemetry.get("received_text") and now - started > first_token_timeout:
                raise TimeoutError(f"sin primer token en {first_token_timeout:.0f}s")

        while True:
            check_timeouts()
            try:
                raw = await asyncio.wait_for(resp.content.readany(), timeout=stall_timeout)
            except asyncio.TimeoutError as exc:
                raise TimeoutError(f"stream detenido {stall_timeout:.0f}s sin datos") from exc
            if not raw:
                break
            last_progress = time.monotonic()
            try:
                buffer += decoder.decode(raw)
            except Exception as exc:
                raise RuntimeError(f"respuesta SSE no decodificable: {exc}") from exc
            while "\n" in buffer:
                raw_line, buffer = buffer.split("\n", 1)
                line = raw_line[:-1] if raw_line.endswith("\r") else raw_line
                if line == "":
                    if data_lines:
                        event_text = "\n".join(data_lines)
                        data_lines = []
                        if event_text.strip() == "[DONE]":
                            telemetry["stream_done"] = True
                            return
                        text = OmniRouteClient._sse_text(event_text, telemetry)
                        if text:
                            last_progress = time.monotonic()
                            yield text
                elif line.startswith(":"):
                    continue
                elif line.startswith("data:"):
                    data_lines.append(line[5:].lstrip(" ") if line.startswith("data: ") else line[5:])
                elif line == "data":
                    data_lines.append("")

        try:
            buffer += decoder.decode(b"", True)
        except Exception as exc:
            raise RuntimeError(f"respuesta SSE incompleta: {exc}") from exc
        if data_lines:
            event_text = "\n".join(data_lines)
            if event_text.strip() == "[DONE]":
                telemetry["stream_done"] = True
                return
            text = OmniRouteClient._sse_text(event_text, telemetry)
            if text:
                yield text
        elif buffer.strip() and not telemetry.get("received_text"):
            # Algunos endpoints compatibles responden JSON completo aunque se
            # pidió stream. Úsalo una vez en lugar de pedirlo de nuevo.
            text = OmniRouteClient._sse_text(buffer, telemetry)
            if text:
                telemetry["non_sse_response"] = True
                yield text
        telemetry["stream_done"] = True
        return

    @staticmethod
    def _sse_text(payload: str, telemetry: Dict[str, Any]) -> str:
        """Extrae texto y uso de un evento SSE sin emitir diagnósticos."""
        text = (payload or "").strip()
        if not text or text == "[DONE]":
            return ""
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return ""
        if isinstance(data, dict) and "error" in data:
            raise RuntimeError(f"stream SSE con error: {data.get('error')}")
        usage = data.get("usage") if isinstance(data, dict) else None
        if isinstance(usage, dict):
            telemetry["prompt_tokens"] = usage.get("prompt_tokens", telemetry.get("prompt_tokens"))
            telemetry["completion_tokens"] = usage.get("completion_tokens", telemetry.get("completion_tokens"))
            telemetry["total_tokens"] = usage.get("total_tokens", telemetry.get("total_tokens"))
        choices = data.get("choices", []) if isinstance(data, dict) else []
        if not choices or not isinstance(choices[0], dict):
            return ""
        delta = choices[0].get("delta", {})
        if not isinstance(delta, dict):
            return ""
        content = delta.get("content", "")
        reasoning = delta.get("reasoning_content", "")
        if not content:
            # Algunos endpoints compatibles devuelven el objeto completo aunque
            # se pidió stream. Acéptalo una vez en lugar de pedirlo de nuevo.
            message = choices[0].get("message", {})
            if isinstance(message, dict):
                content = message.get("content", "")
        if isinstance(reasoning, str) and reasoning:
            telemetry["reasoning_chars"] = telemetry.get("reasoning_chars", 0) + len(reasoning)
            telemetry["reasoning"] = (telemetry.get("reasoning", "") + reasoning)[-4000:]
        if not isinstance(content, str) or not content:
            return ""
        telemetry["received_text"] = True
        if telemetry.get("first_token_at") is None:
            telemetry["first_token_at"] = time.monotonic()
        telemetry["stream_chunks"] = telemetry.get("stream_chunks", 0) + 1
        telemetry["stream_chars"] = telemetry.get("stream_chars", 0) + len(content)
        return content

    @staticmethod
    def _unsupported_stream_options(body: str) -> bool:
        text = (body or "").lower()
        return "stream_options" in text and any(
            token in text for token in (
                "unsupported",
                "not supported",
                "not support",
                "unknown",
                "unexpected",
                "unrecognized",
                "invalid",
            )
        )

    @staticmethod
    def _retry_after_seconds(resp) -> float:
        try:
            return max(0.0, float(resp.headers.get("Retry-After", "2")))
        except (TypeError, ValueError):
            return 2.0

    async def chat_completion_stream(
        self,
        messages: List[Dict[str, str]],
        task: str = "kb_fallback",
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        stats: Optional[Dict[str, Any]] = None,
    ):
        """Generator SSE robusto que produce solo texto nuevo.

        Reintenta únicamente antes del primer fragmento. Después del primer
        fragmento, cualquier error se propaga para que el llamador finalice el
        parcial visible en lugar de duplicar la respuesta.
        """
        model_cfg = self.config.get_model(task)
        telemetry = stats if stats is not None else {}
        telemetry.update({
            "requested_model": model_cfg.name,
            "temperature": temperature if temperature is not None else model_cfg.temperature,
            "max_tokens": max_tokens or model_cfg.max_tokens,
            "attempts": 0,
            "stream_options_supported": True,
            "received_text": False,
            "stream_chunks": 0,
            "stream_chars": 0,
            "reasoning_chars": 0,
            "sent_at": time.monotonic(),
            "first_token_at": None,
        })
        for include_usage in (True, False):
            payload = {
                "model": model_cfg.name,
                "messages": messages,
                "temperature": telemetry["temperature"],
                "max_tokens": telemetry["max_tokens"],
                "stream": True,
            }
            if include_usage:
                payload["stream_options"] = {"include_usage": True}
            for attempt in range(self.config.max_retries + 1):
                telemetry["attempts"] = telemetry.get("attempts", 0) + 1
                try:
                    async with self.session.post(self._endpoint(), json=payload) as resp:
                        if resp.status == 429:
                            await asyncio.sleep(self._retry_after_seconds(resp))
                            continue
                        if resp.status == 400 and include_usage:
                            body = await resp.text()
                            if self._unsupported_stream_options(body):
                                telemetry["stream_options_supported"] = False
                                break
                            raise aiohttp.ClientResponseError(
                                request_info=resp.request_info,
                                history=resp.history,
                                status=resp.status,
                                message=f"Server error {resp.status}",
                            )
                        if resp.status != 200:
                            raise aiohttp.ClientResponseError(
                                request_info=resp.request_info,
                                history=resp.history,
                                status=resp.status,
                                message=f"Server error {resp.status}",
                            )
                        received = False
                        async for text in self._read_sse_body(resp, telemetry):
                            received = True
                            yield text
                        return
                except (aiohttp.ClientResponseError, aiohttp.ClientError, asyncio.TimeoutError) as exc:
                    if telemetry.get("received_text"):
                        raise
                    if attempt < self.config.max_retries:
                        await asyncio.sleep(self.config.retry_delay * (2 ** attempt))
                        continue
                    raise


def load_config_from_env_or_yaml(config_path: Optional[str] = None) -> OmniRouteConfig:
    """Carga config desde YAML (si existe) o variables de entorno."""
    if config_path and Path(config_path).exists():
        return OmniRouteConfig.from_yaml(config_path)
    # Fallback: env vars
    return OmniRouteConfig(
        base_url=os.environ.get("OMNIROUTE_BASE_URL", "https://api.omniroute.ai/v1"),
        api_key=os.environ.get("OMNIROUTE_API_KEY", ""),
        default_models={
            "kb_fallback": os.environ.get("OMNIROUTE_MODEL_KB", "gpt-4o-mini"),
            "reasoning": os.environ.get("OMNIROUTE_MODEL_REASONING", "gpt-4o"),
            "summarize": os.environ.get("OMNIROUTE_MODEL_SUMMARIZE", "gpt-4o-mini"),
            "quick": os.environ.get("OMNIROUTE_MODEL_QUICK", "gpt-4o-mini"),
        },
    )


if __name__ == "__main__":
    import argparse
    import sys

    async def main():
        parser = argparse.ArgumentParser(description="OmniRoute client test")
        parser.add_argument("--config", help="Path a config.yaml")
        parser.add_argument("--task", default="kb_fallback", help="Task para elegir modelo")
        parser.add_argument("--prompt", required=True, help="Prompt de prueba")
        args = parser.parse_args()

        cfg = load_config_from_env_or_yaml(args.config)
        async with OmniRouteClient(cfg) as client:
            resp = await client.chat_completion(
                [{"role": "user", "content": args.prompt}],
                task=args.task,
            )
            print(resp)

    asyncio.run(main())