#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

# OVHcloud AI Deploy startup script for ComfyUI + LTX-2.3 two-stage distilled workflow.
# Designed to run as OVHcloud UID/GID 42420:42420 (no sudo, apt-get or /var/log writes).

DATA_DIR="${COMFY_DATA_DIR:-/workspace/comfy-data}"
RUNTIME_DIR="${COMFY_RUNTIME_DIR:-/workspace/comfy-runtime}"
COMFY_CODE_DIR="${COMFY_CODE_DIR:-${RUNTIME_DIR}/ComfyUI}"
CUSTOM_NODES_DIR="${DATA_DIR}/custom_nodes"
LTX_NODE_DIR="${CUSTOM_NODES_DIR}/ComfyUI-LTXVideo"
PYTHON_PACKAGES="${RUNTIME_DIR}/python-packages"
PORT="${COMFYUI_PORT_HOST:-8188}"

# Pinned revisions validated together. Override with environment variables to update deliberately.
COMFY_REF="${COMFY_REF:-87d23b81765161624889febfb3b81f19f3c8435b}"
LTX_NODES_REF="${LTX_NODES_REF:-aceeae9635f6d493f2893ba3c411a1c36031788a}"

BASE_MODEL_NAME="ltx-2.3-22b-dev.safetensors"
LORA_NAME="ltx-2.3-22b-distilled-lora-384-1.1.safetensors"
UPSCALER_NAME="ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
TEXT_ENCODER_NAME="gemma_3_12B_it_fp8_scaled.safetensors"
WORKFLOW_NAME="LTX-2.3_T2V_I2V_Two_Stage_Distilled_OVH.json"

BASE_MODEL_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/${BASE_MODEL_NAME}"
LORA_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/${LORA_NAME}"
UPSCALER_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/${UPSCALER_NAME}"
TEXT_ENCODER_URL="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/${TEXT_ENCODER_NAME}"

log()  { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*"; }
warn() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] WARN: %s\n' -1 "$*" >&2; }
die()  { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] ERROR: %s\n' -1 "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '[%(%Y-%m-%dT%H:%M:%S%z)T] ERROR: command failed at line %s (exit %s)\n' \
        -1 "${BASH_LINENO[0]:-unknown}" "$rc" >&2
    exit "$rc"
}
trap on_error ERR

command -v git >/dev/null 2>&1 || die "git is missing from the Docker image"

PYTHON="${COMFYUI_VENV_PYTHON:-/opt/environments/python/comfyui/bin/python}"
if [[ ! -x "$PYTHON" ]]; then
    PYTHON="$(command -v python3 || true)"
fi
[[ -n "$PYTHON" && -x "$PYTHON" ]] || die "Python executable was not found"

mkdir -p \
    "$RUNTIME_DIR/home" \
    "$RUNTIME_DIR/cache/huggingface" \
    "$RUNTIME_DIR/cache/pip" \
    "$RUNTIME_DIR/tmp" \
    "$PYTHON_PACKAGES" \
    "$CUSTOM_NODES_DIR" \
    "$DATA_DIR/models/checkpoints" \
    "$DATA_DIR/models/loras/ltxv/ltx2" \
    "$DATA_DIR/models/latent_upscale_models" \
    "$DATA_DIR/models/text_encoders" \
    "$DATA_DIR/input" \
    "$DATA_DIR/output" \
    "$DATA_DIR/temp" \
    "$DATA_DIR/user/default/workflows"

export HOME="$RUNTIME_DIR/home"
export HF_HOME="$RUNTIME_DIR/cache/huggingface"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export PIP_CACHE_DIR="$RUNTIME_DIR/cache/pip"
export TMPDIR="$RUNTIME_DIR/tmp"
export PYTHONPATH="${PYTHON_PACKAGES}${PYTHONPATH:+:${PYTHONPATH}}"
export PYTHONUNBUFFERED=1

log "Running as: $(id)"
log "Python: $PYTHON"
log "Persistent data directory: $DATA_DIR"
log "Runtime directory: $RUNTIME_DIR"

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
    gpu_mem_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
    if [[ "$gpu_mem_mib" =~ ^[0-9]+$ ]] && (( gpu_mem_mib < 32000 )); then
        warn "LTX-2.3 officially targets 32 GB+ VRAM; this GPU reports ${gpu_mem_mib} MiB"
    fi
else
    warn "nvidia-smi was not found; GPU availability could not be verified"
fi

checkout_repo() {
    local url="$1"
    local target="$2"
    local ref="$3"

    if [[ ! -d "$target/.git" ]]; then
        rm -rf "$target"
        mkdir -p "$target"
        git -C "$target" init -q
        git -C "$target" remote add origin "$url"
    fi

    log "Fetching ${url} at ${ref}"
    git -C "$target" fetch -q --depth 1 origin "$ref"
    git -C "$target" checkout -q --detach FETCH_HEAD
    git -C "$target" clean -ffdq
}

checkout_repo "https://github.com/Comfy-Org/ComfyUI.git" "$COMFY_CODE_DIR" "$COMFY_REF"
checkout_repo "https://github.com/Lightricks/ComfyUI-LTXVideo.git" "$LTX_NODE_DIR" "$LTX_NODES_REF"

# Install current ComfyUI userspace dependencies, but retain CUDA-enabled torch packages
# supplied by the Docker image. Everything is installed into a writable directory.
COMFY_REQ_FILTERED="$RUNTIME_DIR/comfy-requirements-without-torch.txt"
grep -Ev '^(torch|torchvision|torchaudio)([[:space:]<>=~!].*)?$' \
    "$COMFY_CODE_DIR/requirements.txt" > "$COMFY_REQ_FILTERED"

requirements_hash="$(
    cat "$COMFY_REQ_FILTERED" "$LTX_NODE_DIR/requirements.txt" | sha256sum | awk '{print $1}'
)"
requirements_marker="$PYTHON_PACKAGES/.installed-${requirements_hash}"

if [[ ! -f "$requirements_marker" ]]; then
    log "Installing ComfyUI and LTX node Python dependencies"
    "$PYTHON" -m pip install \
        --disable-pip-version-check \
        --upgrade \
        --target "$PYTHON_PACKAGES" \
        -r "$COMFY_REQ_FILTERED" \
        -r "$LTX_NODE_DIR/requirements.txt"
    rm -f "$PYTHON_PACKAGES"/.installed-*
    touch "$requirements_marker"
else
    log "Python dependencies are already installed"
fi

download_file() {
    local url="$1"
    local destination="$2"
    local minimum_size="$3"
    local current_size=0

    if [[ -f "$destination" ]]; then
        current_size="$(stat -c '%s' "$destination" 2>/dev/null || echo 0)"
        if (( current_size >= minimum_size )); then
            log "Cached: $(basename "$destination") ($(( current_size / 1073741824 )) GiB)"
            return 0
        fi
        warn "Incomplete file detected: $destination (${current_size} bytes)"
    fi

    local directory temporary
    directory="$(dirname "$destination")"
    temporary="${destination}.part"
    [[ -w "$directory" ]] || die "Directory is read-only and model is missing: $directory"

    log "Downloading: $(basename "$destination")"

    if command -v aria2c >/dev/null 2>&1; then
        local -a aria_args=(
            --continue=true
            --max-connection-per-server=16
            --split=16
            --min-split-size=16M
            --file-allocation=none
            --console-log-level=warn
            --dir="$directory"
            --out="$(basename "$temporary")"
        )
        if [[ -n "${HF_TOKEN:-}" ]]; then
            aria_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
        fi
        aria2c "${aria_args[@]}" "$url"
    elif command -v curl >/dev/null 2>&1; then
        local -a curl_args=(
            --fail
            --location
            --retry 8
            --retry-delay 3
            --retry-all-errors
            --continue-at -
            --output "$temporary"
        )
        if [[ -n "${HF_TOKEN:-}" ]]; then
            curl_args+=(--header "Authorization: Bearer ${HF_TOKEN}")
        fi
        curl "${curl_args[@]}" "$url"
    else
        die "Neither aria2c nor curl is available in the Docker image"
    fi

    current_size="$(stat -c '%s' "$temporary" 2>/dev/null || echo 0)"
    (( current_size >= minimum_size )) || die \
        "Downloaded file is too small: $temporary (${current_size} bytes, expected at least ${minimum_size})"

    mv -f "$temporary" "$destination"
    log "Downloaded: $destination"
}

# The requested 7.6 GB file is a distilled LoRA adapter, not a standalone checkpoint.
# The official two-stage workflow applies it to the 46.1 GB LTX-2.3 dev checkpoint.
download_file \
    "$BASE_MODEL_URL" \
    "$DATA_DIR/models/checkpoints/$BASE_MODEL_NAME" \
    42000000000

download_file \
    "$LORA_URL" \
    "$DATA_DIR/models/loras/ltxv/ltx2/$LORA_NAME" \
    7000000000

download_file \
    "$UPSCALER_URL" \
    "$DATA_DIR/models/latent_upscale_models/$UPSCALER_NAME" \
    900000000

download_file \
    "$TEXT_ENCODER_URL" \
    "$DATA_DIR/models/text_encoders/$TEXT_ENCODER_NAME" \
    12000000000

WORKFLOW_SOURCE="$LTX_NODE_DIR/example_workflows/2.3/LTX-2.3_T2V_I2V_Two_Stage_Distilled.json"
WORKFLOW_DEST="$DATA_DIR/user/default/workflows/$WORKFLOW_NAME"
[[ -f "$WORKFLOW_SOURCE" ]] || die "Official LTX-2.3 workflow was not found: $WORKFLOW_SOURCE"

# Patch only the text-encoder filename. Base model, LoRA path, upscaler and official
# sampling settings remain unchanged.
"$PYTHON" - "$WORKFLOW_SOURCE" "$WORKFLOW_DEST" "$TEXT_ENCODER_NAME" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
text_encoder_name = sys.argv[3]

with source.open("r", encoding="utf-8") as fh:
    workflow = json.load(fh)

old_name = "comfy_gemma_3_12B_it.safetensors"
replacement_count = 0

def patch(value):
    global replacement_count
    if isinstance(value, dict):
        return {key: patch(item) for key, item in value.items()}
    if isinstance(value, list):
        return [patch(item) for item in value]
    if value == old_name:
        replacement_count += 1
        return text_encoder_name
    return value

workflow = patch(workflow)
if replacement_count == 0:
    raise RuntimeError(f"Expected text encoder reference {old_name!r} was not found")

serialized = json.dumps(workflow, ensure_ascii=False, indent=2)
required = (
    "ltx-2.3-22b-dev.safetensors",
    "ltx-2.3-22b-distilled-lora-384-1.1.safetensors",
    "ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
    text_encoder_name,
)
missing = [name for name in required if name not in serialized]
if missing:
    raise RuntimeError(f"Workflow validation failed; missing references: {missing}")

destination.parent.mkdir(parents=True, exist_ok=True)
temporary = destination.with_suffix(destination.suffix + ".tmp")
with temporary.open("w", encoding="utf-8", newline="\n") as fh:
    json.dump(workflow, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
temporary.replace(destination)
print(f"Workflow installed: {destination}")
PY

log "Model directory usage:"
du -sh "$DATA_DIR/models" 2>/dev/null || true
log "Workflow: $WORKFLOW_DEST"
log "Starting ComfyUI on 0.0.0.0:${PORT}"

extra_args=()
if [[ -n "${COMFYUI_ARGS:-}" ]]; then
    # Intended for uncomplicated whitespace-separated flags, for example:
    # COMFYUI_ARGS="--reserve-vram 2 --preview-method auto"
    read -r -a extra_args <<< "$COMFYUI_ARGS"
fi

exec "$PYTHON" "$COMFY_CODE_DIR/main.py" \
    --listen 0.0.0.0 \
    --port "$PORT" \
    --base-directory "$DATA_DIR" \
    --disable-auto-launch \
    "${extra_args[@]}"
