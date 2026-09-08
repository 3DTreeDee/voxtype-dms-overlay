#!/usr/bin/env bash
# voxtype-model-swap.sh — Swap automático del modelo Whisper de voxtype según modo.
#
# Modo "dictado"   -> modelo ligero (small por defecto) — rapidez interactiva.
# Modo "reuniones" -> modelo potente (medium por defecto) — precisión entre personas.
#
# Ideas del diseño:
# - Cambia `whisper.model` y decide qué modelo usar al iniciar/terminar reuniones.
# - Guarda el estado en un statefile para saber a qué modelo revertir.
# - Valida que el modelo exista/sea descargable antes de intentar el swap.
# - Tras cambiar config, reinicia el daemon de voxtype (requerido para que surta efecto).
#
# Uso:
#   voxtype-model-swap.sh dictado          # poner modelo de dictado
#   voxtype-model-swap.sh reunion          # poner modelo de reuniones (+ guarda previo)
#   voxtype-model-swap.sh status           # mostrar modelo activo y estado
#   voxtype-model-swap.sh revert           # volver al modelo que estaba antes del swap

set -euo pipefail

CONFIG_FILE="${VOXTYPE_CONFIG:-$HOME/.config/voxtype/config.toml}"
STATE_DIR="${VOXTYPE_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/voxtype}"
STATE_FILE="$STATE_DIR/model_swap.json"
SERVICE="${VOXTYPE_SERVICE:-voxtype}"
SYSTEMCTL="systemctl --user"

# Modelos por defecto (se overridan desde estado/cfg del plugin via env)
MODEL_DICTADO="${VOXTYPE_MODEL_DICTADO:-small}"
MODEL_REUNION="${VOXTYPE_MODEL_REUNION:-large-v3-turbo}"

# ---------------------------------------------------------------------------

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "• $*"; }

mkdir -p "$STATE_DIR"

current_model() {
    # leer whisper.model del config.toml
    local val
    val=$(awk -F'=' '/^\s*model\s*=/ {gsub(/[ "\t]/,"",$2); print $2}' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$val" ]]; then
        # puede estar en sección [whisper]; buscar contexto
        val=$(awk '/\[whisper\]/{f=1} f&&/model/{gsub(/[ "\t]/,"",$2); print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)
    fi
    [[ -z "$val" ]] && val="small"
    echo "$val"
}

save_state() {
    cat > "$STATE_FILE" <<JSON
{
  "previous": $(echo "$1" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().strip()))'),
  "current": "$(current_model)",
  "updated_at": $(date +%s)
}
JSON
}

load_previous() {
    if [[ -f "$STATE_FILE" ]]; then
        python3 -c "import json,sys;print(json.load(open('$STATE_FILE')).get('previous','null'))" 2>/dev/null || echo "null"
    else
        echo "null"
    fi
}

# Validar que el modelo existe (descargable o instalado)
model_available() {
    local m="$1"
    voxtype info models --json 2>/dev/null | python3 -c "
import sys, json
m = '$m'
try:
    data = json.load(sys.stdin)
    for eng in data['engines'].values():
        for mod in eng.get('models', []):
            if mod['name'] == m:
                print('ok'); sys.exit(0)
    print('missing'); sys.exit(1)
except Exception:
    sys.exit(1)
"
}

# Descargar modelo si no está instalado y es descargable
ensure_model() {
    local m="$1"
    if ! model_available "$m" >/dev/null; then
        info "Modelo '$m' no disponible; descargando..."
        voxtype setup --model "$m" --download || die "No se pudo descargar '$m'"
    fi
}

set_model() {
    local m="$1"
    if [[ "$(current_model)" == "$m" ]]; then
        info "Modelo '$m' ya activo."
        return 0
    fi
    ensure_model "$m"
    info "Cambiando whisper.model -> $m"
    voxtype config set whisper.model "$m"
    info "Reiniciando servicio voxtype..."
    $SYSTEMCTL restart "$SERVICE"
    info "Modelo activo ahora: $m"
}

# ---------------------------------------------------------------------------

case "${1:-}" in
    dictado)
        echo "{\"mode\":\"dictado\",\"model\":\"$MODEL_DICTADO\"}"
        save_state "$(current_model | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().strip()))')"
        set_model "$MODEL_DICTADO"
        ;;
    reunion)
        echo "{\"mode\":\"reunion\",\"model\":\"$MODEL_REUNION\"}"
        save_state "$(current_model | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().strip()))')"
        set_model "$MODEL_REUNION"
        ;;
    revert)
        local prev
        prev=$(load_previous)
        if [[ "$prev" == "null" ]]; then
            info "Sin estado previo; usando modelo de dictado."
            set_model "$MODEL_DICTADO"
        else
            info "Revirtiendo a modelo previo: $prev"
            set_model "$prev"
            rm -f "$STATE_FILE"
        fi
        ;;
    status)
        echo "Modelo activo: $(current_model)"
        echo "Estado: $([ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo 'sin swap activo')"
        ;;
    *)
        die "Uso: $0 {dictado|reunion|revert|status}"
        ;;
esac