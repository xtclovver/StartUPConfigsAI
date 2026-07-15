#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${COMFY_BASE_DIR:-/workspace/comfy-data}"
STARTUP_DIR="${STARTUP_DIR:-/workspace/startup}"
COMFY_CODE="${COMFY_CODE_DIR:-/opt/ComfyUI}"
PORT="${COMFYUI_PORT_HOST:-8188}"

CHECKPOINT_NAME="wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors"
CLIP_VISION_NAME="clip_vision_h.safetensors"

CHECKPOINT_URL="https://huggingface.co/Phr00t/WAN2.2-14B-Rapid-AllInOne/resolve/main/Mega-v12/${CHECKPOINT_NAME}"
CLIP_VISION_URL="https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/${CLIP_VISION_NAME}"

PYTHON="${COMFYUI_VENV_PYTHON:-/opt/environments/python/comfyui/bin/python}"

if [[ ! -x "$PYTHON" ]]; then
    PYTHON="$(command -v python3 || true)"
fi

if [[ -z "$PYTHON" || ! -x "$PYTHON" ]]; then
    echo "[ERROR] Python executable not found" >&2
    exit 1
fi

if [[ ! -f "${COMFY_CODE}/main.py" ]]; then
    echo "[ERROR] ComfyUI not found at ${COMFY_CODE}" >&2
    exit 1
fi

export HOME="${BASE_DIR}/home"
export XDG_CACHE_HOME="${BASE_DIR}/cache"
export PIP_CACHE_DIR="${BASE_DIR}/cache/pip"
export TMPDIR="${BASE_DIR}/tmp"

PYTHON_PACKAGES="${BASE_DIR}/python-packages"
export PYTHONPATH="${PYTHON_PACKAGES}${PYTHONPATH:+:${PYTHONPATH}}"

mkdir -p \
    "$HOME" \
    "$XDG_CACHE_HOME" \
    "$PIP_CACHE_DIR" \
    "$TMPDIR" \
    "$PYTHON_PACKAGES" \
    "${BASE_DIR}/custom_nodes" \
    "${BASE_DIR}/models/checkpoints" \
    "${BASE_DIR}/models/clip_vision" \
    "${BASE_DIR}/input" \
    "${BASE_DIR}/output" \
    "${BASE_DIR}/user/default/workflows"

echo "[INFO] User: $(id)"
echo "[INFO] Python: ${PYTHON}"
echo "[INFO] ComfyUI code: ${COMFY_CODE}"
echo "[INFO] Writable data: ${BASE_DIR}"

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total \
        --format=csv,noheader || true
else
    echo "[WARN] nvidia-smi not found"
fi

# Custom node
VHS_DIR="${BASE_DIR}/custom_nodes/ComfyUI-VideoHelperSuite"

if [[ ! -d "${VHS_DIR}/.git" ]]; then
    command -v git >/dev/null 2>&1 || {
        echo "[ERROR] git is not installed in the Docker image" >&2
        exit 1
    }

    echo "[INFO] Installing ComfyUI-VideoHelperSuite"
    git clone --depth 1 \
        https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        "$VHS_DIR"
fi

if [[ -f "${VHS_DIR}/requirements.txt" ]]; then
    echo "[INFO] Installing custom-node Python dependencies"
    "$PYTHON" -m pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        --upgrade \
        --target "$PYTHON_PACKAGES" \
        -r "${VHS_DIR}/requirements.txt"
fi

download_file() {
    local url="$1"
    local destination="$2"
    local minimum_size="$3"

    if [[ -f "$destination" ]]; then
        local current_size
        current_size="$(stat -c '%s' "$destination" 2>/dev/null || echo 0)"

        if (( current_size >= minimum_size )); then
            echo "[INFO] Cached: $(basename "$destination")"
            return
        fi
    fi

    local directory
    directory="$(dirname "$destination")"

    if [[ ! -w "$directory" ]]; then
        echo "[ERROR] ${directory} is read-only and the model is missing." >&2
        echo "[ERROR] Upload the model to Object Storage before deployment." >&2
        exit 1
    fi

    local temporary="${destination}.part"
    echo "[INFO] Downloading: $(basename "$destination")"

    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
            --continue=true \
            -x 16 \
            -s 16 \
            -k 1M \
            --console-log-level=warn \
            -d "$directory" \
            -o "$(basename "$temporary")" \
            "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl \
            --fail \
            --location \
            --retry 5 \
            --retry-all-errors \
            --continue-at - \
            --output "$temporary" \
            "$url"
    else
        echo "[ERROR] Neither aria2c nor curl is installed" >&2
        exit 1
    fi

    mv "$temporary" "$destination"

    local final_size
    final_size="$(stat -c '%s' "$destination" 2>/dev/null || echo 0)"

    if (( final_size < minimum_size )); then
        echo "[ERROR] Downloaded file is unexpectedly small: ${destination}" >&2
        exit 1
    fi
}

download_file \
    "$CHECKPOINT_URL" \
    "${BASE_DIR}/models/checkpoints/${CHECKPOINT_NAME}" \
    20000000000

download_file \
    "$CLIP_VISION_URL" \
    "${BASE_DIR}/models/clip_vision/${CLIP_VISION_NAME}" \
    3000000000

WORKFLOW_SOURCE="${STARTUP_DIR}/comfy_wf_wan2.2-ti2v-aio_uncensored.json"
WORKFLOW_DESTINATION="${BASE_DIR}/user/default/workflows/wan22-ti2v-aio.json"

if [[ -f "$WORKFLOW_SOURCE" ]]; then
    cp -f "$WORKFLOW_SOURCE" "$WORKFLOW_DESTINATION"
    echo "[INFO] Workflow installed: ${WORKFLOW_DESTINATION}"
else
    echo "[WARN] Workflow not found: ${WORKFLOW_SOURCE}"
fi

EXTRA_ARGS=()

if [[ -n "${COMFYUI_ARGS:-}" ]]; then
    # Подходит для простых аргументов без сложного shell quoting.
    read -r -a EXTRA_ARGS <<< "$COMFYUI_ARGS"
fi

echo "[INFO] Starting ComfyUI on 0.0.0.0:${PORT}"

exec "$PYTHON" "${COMFY_CODE}/main.py" \
    --listen 0.0.0.0 \
    --port "$PORT" \
    --base-directory "$BASE_DIR" \
    --disable-auto-launch \
    "${EXTRA_ARGS[@]}"
