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
        VIRTUAL_ENV="$VENV_DIR" uv pip install -r "$REQ" >&2
    else
        "$VENV_DIR/bin/pip" install -r "$REQ" >&2
    fi
    echo "$REQ_HASH" > "$STAMP"
    log "dependencias listas"
fi

# 3) Ejecutar el auditor con el python del venv
exec "$VENV_DIR/bin/python3" "$SCRIPT_DIR/auditor.py" "$@"
