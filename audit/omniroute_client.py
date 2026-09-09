#!/usr/bin/env python3
"""
omniroute_client.py — Cliente para OmniRoute / OpenAI-compatible API.
Soporta múltiples proveedores con endpoint/base_url + API key.
Configurable: modelos/combos por tipo de tarea.
"""

import os
import json
import asyncio
import aiohttp
import time
from typing import Dict, List, Optional, Any, Literal
from dataclasses import dataclass, field, asdict
from pathlib import Path
import yaml


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
    ) -> str:
        """
        Completion no-streaming. Retorna el content del primer choice.
        """
        model_cfg = self.config.get_model(task)
        payload = {
            "model": model_cfg.name,
            "messages": messages,
            "temperature": temperature if temperature is not None else model_cfg.temperature,
            "max_tokens": max_tokens or model_cfg.max_tokens,
            "stream": stream,
        }
        if stream:
            raise NotImplementedError("Streaming no implementado aún; usar sync")

        data = await self._request_with_retry(payload)
        try:
            return data["choices"][0]["message"]["content"].strip()
        except (KeyError, IndexError):
            raise RuntimeError(f"Respuesta inesperada: {data}")

    async def chat_completion_stream(
        self,
        messages: List[Dict[str, str]],
        task: str = "kb_fallback",
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
    ):
        """Generator que yield chunks de texto."""
        model_cfg = self.config.get_model(task)
        payload = {
            "model": model_cfg.name,
            "messages": messages,
            "temperature": temperature if temperature is not None else model_cfg.temperature,
            "max_tokens": max_tokens or model_cfg.max_tokens,
            "stream": True,
        }
        async with self.session.post(self._endpoint(), json=payload) as resp:
            async for line in resp.content:
                line = line.decode("utf-8").strip()
                if line.startswith("data: "):
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk["choices"][0]["delta"]
                        if "content" in delta:
                            yield delta["content"]
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue


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