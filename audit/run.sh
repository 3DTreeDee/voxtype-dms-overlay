#!/usr/bin/env bash
# run.sh — arranca el auditor.py con HF offline y credenciales IA desde
#          plugin_settings.json (sin exponer API keys en argv).
set -euo pipefail

export HF_HUB_OFFLINE=1

# Cargar config IA desde plugin_settings.json y exportarla como env vars.
# El bloque python imprime "export VAR=valor" que bash evalúa ANTES de exec.
eval "$(python3 -c "
import json, os
try:
    d = json.load(open(os.path.expanduser('~/.config/DankMaterialShell/plugin_settings.json')))
except Exception:
    d = {}
v = d.get('voxtypeOverlay', {})
lines = []
for k, e in [
    ('auditorAiBaseUrl', 'OMNIROUTE_BASE_URL'),
    ('auditorAiApiKey', 'OMNIROUTE_API_KEY'),
    ('auditorAiModel',  'OMNIROUTE_MODEL_KB'),
    ('auditorAutoReply', 'AUDITOR_AUTO_REPLY'),
    ('auditorVaultSearch', 'AUDITOR_VAULT_SEARCH'),
    ('auditorKbThreshold', 'AUDITOR_KB_THRESHOLD'),
]:
    val = v.get(k)
    if val is None or val == '':
        continue
    if isinstance(val, bool):
        val = 'true' if val else 'false'
    elif k == 'auditorKbThreshold':
        try:
            pct = int(val)
            val = str(max(0, min(100, pct)) / 100.0)
        except ValueError:
            val = '0.70'
    lines.append(f'export {e}={val}')
print('; '.join(lines), flush=True)
")"

VENV="${HOME}/.local/share/voxtype-auditor/venv"
AUDIT_DIR="${HOME}/Proyectos/GitHub/voxtype-dms-overlay/audit"

exec "${VENV}/bin/python" "${AUDIT_DIR}/auditor.py" "$@"