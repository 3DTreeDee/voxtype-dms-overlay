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
    # Escribe JSON de una sola codificación. "$1" = modelo previo (texto plano).
    python3 -c 'import json,sys,time; json.dump({"previous": sys.argv[1], "current": sys.argv[2], "updated_at": int(time.time())}, open(sys.argv[3], "w"))' \
        "$1" "$(current_model)" "$STATE_FILE"
}

load_previous() {
    if [[ -f "$STATE_FILE" ]]; then
        python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("previous"); print(v if v else "null")' "$STATE_FILE" 2>/dev/null || echo "null"
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
        # Fuerza el modelo de dictado (opcional: $2 = modelo).
        [[ -n "${2:-}" ]] && MODEL_DICTADO="$2"
        echo "{\"mode\":\"dictado\",\"model\":\"$MODEL_DICTADO\"}"
        set_model "$MODEL_DICTADO"
        ;;
    reunion)
        # $2 = modelo de reunión, $3 = modelo de dictado (guardado para revert).
        [[ -n "${2:-}" ]] && MODEL_REUNION="$2"
        [[ -n "${3:-}" ]] && MODEL_DICTADO="$3"
        echo "{\"mode\":\"reunion\",\"model\":\"$MODEL_REUNION\"}"
        # Guarda el modelo actual (texto plano) para poder revertir.
        save_state "$(current_model)"
        set_model "$MODEL_REUNION"
        ;;
    revert)
        prev="$(load_previous)"
        if [[ -z "$prev" || "$prev" == "null" ]]; then
            info "Sin estado previo; usando modelo de dictado ($MODEL_DICTADO)."
            set_model "$MODEL_DICTADO"
        elif [[ "$(current_model)" == "$prev" ]]; then
            info "Ya en el modelo previo ($prev); nada que revertir."
        else
            info "Revirtiendo a modelo previo: $prev"
            set_model "$prev"
        fi
        rm -f "$STATE_FILE"
        ;;
    status)
        echo "Modelo activo: $(current_model)"
        echo "Estado: $([ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo 'sin swap activo')"
        ;;
    *)
        die "Uso: $0 {dictado|reunion|revert|status}"
        ;;
esac