#!/usr/bin/env python3
"""check_omniroute.py — prueba la conexión con el endpoint del auditor.

Lee auditorAiBaseUrl/auditorAiApiKey de plugin_settings.json (igual que
run.sh), hace GET {base}/models y emite JSON a stdout:

  OK:   {"ok": true, "base": ..., "latency_ms": N, "count": N,
         "models": [ids...], "auto": [alias auto/*...]}
  FAIL: {"ok": false, "error": "..."}

Solo stdlib (urllib): corre con cualquier python3, sin depender del venv.
La API key nunca viaja por argv — el proceso la lee del propio JSON.
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error


def load_config():
    path = os.path.expanduser("~/.config/DankMaterialShell/plugin_settings.json")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    v = data.get("voxtypeOverlay", {})
    return (v.get("auditorAiBaseUrl") or "").rstrip("/"), v.get("auditorAiApiKey") or ""


def main():
    try:
        base, key = load_config()
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": f"plugin_settings.json: {e}"}))
        return 1

    if not base:
        print(json.dumps({"ok": False, "error": "Falta la base URL (Settings → Auditor IA → API base URL)"}))
        return 1
    if not key:
        print(json.dumps({"ok": False, "error": "Falta la API key (Settings → Auditor IA → API key)"}))
        return 1

    url = base + "/models"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
        latency_ms = int((time.time() - t0) * 1000)
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:200]
        except Exception:  # noqa: BLE001
            pass
        print(json.dumps({"ok": False, "error": f"HTTP {e.code}: {e.reason} {body}"}))
        return 1
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}))
        return 1

    ids = [m.get("id", "") for m in data.get("data", []) if m.get("id")]
    seen, ordered = set(), []
    for i in ids:  # dedupe preservando orden
        if i not in seen:
            seen.add(i)
            ordered.append(i)
    auto = sorted(i for i in ordered if i.startswith("auto/"))
    print(json.dumps({
        "ok": True,
        "base": base,
        "latency_ms": latency_ms,
        "count": len(ordered),
        "models": ordered,
        "auto": auto,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
