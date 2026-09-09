#!/usr/bin/env bash
# run.sh — arranca el auditor.py con HF offline y credenciales IA desde
#          plugin_settings.json (sin exponer API keys en argv).
set -euo pipefail

export HF_HUB_OFFLINE=1

# --- Cargar config IA desde plugin_settings.json (GUI) ---
# Las keys viajan por env (OMNIROUTE_BASE_URL, OMNIROUTE_API_KEY,
# OMNIROUTE_MODEL_KB) que auditor.py ya reconoce en
# load_config_from_env_or_yaml().  Así la API key nunca aparece en argv,
# solo en plugin_settings.json (local) y en la env del proceso hijo.
python3 -c "
import json, os
try:
    d = json.load(open(os.path.expanduser('~/.config/DankMaterialShell/plugin_settings.json')))
    v = d.get('voxtypeOverlay', {})
    for k, e in [
        ('auditorAiBaseUrl', 'OMNIROUTE_BASE_URL'),
        ('auditorAiApiKey', 'OMNIROUTE_API_KEY'),
        ('auditorAiModel',  'OMNIROUTE_MODEL_KB'),
        ('auditorAutoReply', 'AUDITOR_AUTO_REPLY'),
    ]:
        val = v.get(k, '')
        if val:
            os.environ[e] = val
except Exception:
    pass
"

VENV="${HOME}/.local/share/voxtype-auditor/venv"
AUDIT_DIR="${HOME}/Proyectos/GitHub/voxtype-dms-overlay/audit"

# Arrancar auditor.py con los args del daemon (--vault, --kb-db, etc.)
exec "${VENV}/bin/python" "${AUDIT_DIR}/auditor.py" "$@"