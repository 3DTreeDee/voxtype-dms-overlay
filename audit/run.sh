#!/usr/bin/env bash
# Wrapper portable del auditor: crea/usa un venv propio del plugin.
# Uso: run.sh [args de auditor.py...]   (ej: run.sh --vault ~/vault listen)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VOXTYPE_AUDITOR_VENV:-$HOME/.local/share/voxtype-auditor/venv}"
REQ="$SCRIPT_DIR/requirements.txt"
STAMP="$VENV_DIR/.requirements.sha256"

log() { echo "[auditor-run] $*" >&2; }

# 1) Crear venv si no existe (uv si está, si no python3 -m venv)
if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
    log "creando venv en $VENV_DIR ..."
    mkdir -p "$(dirname "$VENV_DIR")"
    if command -v uv >/dev/null 2>&1; then
        uv venv --python 3.11 "$VENV_DIR" 2>/dev/null || uv venv "$VENV_DIR"
    else
        python3 -m venv "$VENV_DIR"
    fi
fi

# 2) Instalar/actualizar deps solo si requirements.txt cambió
REQ_HASH="$(sha256sum "$REQ" | cut -d' ' -f1)"
if [[ ! -f "$STAMP" || "$(cat "$STAMP")" != "$REQ_HASH" ]]; then
    log "instalando dependencias (primera vez puede tardar varios minutos)..."
    if command -v uv >/dev/null 2>&1; then
        # GPU del usuario es AMD (no CUDA): instalar torch desde el índice CPU
        # evita bajar ~2.5GB de paquetes nvidia-* inútiles. El modelo de
        # embeddings (384-d) corre de sobra en CPU.
        VIRTUAL_ENV="$VENV_DIR" uv pip install torch --index-url https://download.pytorch.org/whl/cpu >&2
        VIRTUAL_ENV="$VENV_DIR" uv pip install -r "$REQ" >&2
    else
        "$VENV_DIR/bin/pip" install torch --index-url https://download.pytorch.org/whl/cpu >&2
        "$VENV_DIR/bin/pip" install -r "$REQ" >&2
    fi
    echo "$REQ_HASH" > "$STAMP"
    log "dependencias listas"
fi

# 3) Ejecutar el auditor con el python del venv.
#    HF_HUB_OFFLINE=1: el modelo KB (all-MiniLM-L6-v2) ya está cacheado en
#    ~/.cache/huggingface; sin esto cada arranque pierde 5-10s verificando
#    online y puede perder los primeros segundos de voz del usuario.
export HF_HUB_OFFLINE=1
exec "$VENV_DIR/bin/python3" "$SCRIPT_DIR/auditor.py" "$@"
