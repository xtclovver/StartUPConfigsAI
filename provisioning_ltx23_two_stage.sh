#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

# Vast.ai provisioning for ComfyUI + LTX-2.3 two-stage distilled workflow.
# Target image: vastai/comfy:v0.27.0-cuda-12.9-py312
# Persistent workspace: /workspace

if [[ -f /venv/main/bin/activate ]]; then
    # shellcheck disable=SC1091
    source /venv/main/bin/activate
else
    printf 'ERROR: /venv/main/bin/activate was not found\n' >&2
    exit 1
fi

WORKSPACE="${WORKSPACE:-/workspace}"
WORKSPACE="${WORKSPACE%/}"
COMFYUI_DIR="${COMFYUI_DIR:-${WORKSPACE}/ComfyUI}"
MODELS_DIR="${COMFYUI_DIR}/models"
CUSTOM_NODES_DIR="${COMFYUI_DIR}/custom_nodes"
LTX_NODE_DIR="${CUSTOM_NODES_DIR}/ComfyUI-LTXVideo"
WORKFLOW_DIR="${COMFYUI_DIR}/user/default/workflows"

# Keep the workflow and custom nodes reproducible. Override deliberately via env.
LTX_NODES_REF="${LTX_NODES_REF:-aceeae9635f6d493f2893ba3c411a1c36031788a}"
WORKFLOW_REF="${WORKFLOW_REF:-aceeae9635f6d493f2893ba3c411a1c36031788a}"

BASE_MODEL_NAME="ltx-2.3-22b-dev.safetensors"
LORA_NAME="ltx-2.3-22b-distilled-lora-384-1.1.safetensors"
UPSCALER_NAME="ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
TEXT_ENCODER_NAME="gemma_3_12B_it_fp8_scaled.safetensors"
WORKFLOW_NAME="LTX-2.3_T2V_I2V_Two_Stage_Distilled_Vast.json"

BASE_MODEL_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/${BASE_MODEL_NAME}?download=true"
LORA_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/${LORA_NAME}?download=true"
UPSCALER_URL="https://huggingface.co/Lightricks/LTX-2.3/resolve/main/${UPSCALER_NAME}?download=true"
TEXT_ENCODER_URL="https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/${TEXT_ENCODER_NAME}?download=true"
WORKFLOW_URL="https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/${WORKFLOW_REF}/example_workflows/2.3/LTX-2.3_T2V_I2V_Two_Stage_Distilled.json"

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

[[ -d "$COMFYUI_DIR" ]] || die "ComfyUI directory was not found: $COMFYUI_DIR"
command -v git >/dev/null 2>&1 || die "git is missing from the image"
command -v python >/dev/null 2>&1 || die "python is missing from the active venv"

log "ComfyUI directory: $COMFYUI_DIR"
log "Persistent workspace: $WORKSPACE"
log "Running as: $(id)"

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
    gpu_mem_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
    if [[ "$gpu_mem_mib" =~ ^[0-9]+$ ]] && (( gpu_mem_mib < 32000 )); then
        warn "LTX-2.3 targets 32 GB+ VRAM; this GPU reports ${gpu_mem_mib} MiB"
    fi
else
    warn "nvidia-smi was not found; GPU availability could not be checked"
fi

install_system_packages() {
    local -a missing=()
    command -v aria2c >/dev/null 2>&1 || missing+=(aria2)
    command -v ffmpeg >/dev/null 2>&1 || missing+=(ffmpeg)

    if (( ${#missing[@]} > 0 )); then
        log "Installing system packages: ${missing[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
        rm -rf /var/lib/apt/lists/*
    fi
}

checkout_repo() {
    local url="$1"
    local target="$2"
    local ref="$3"

    if [[ ! -d "$target/.git" ]]; then
        rm -rf "$target"
        log "Cloning: $url"
        git clone --filter=blob:none --no-checkout "$url" "$target"
    fi

    log "Checking out ${url} at ${ref}"
    git -C "$target" fetch --quiet --depth 1 origin "$ref"
    git -C "$target" checkout --quiet --detach FETCH_HEAD
}

install_python_requirements() {
    local requirements="$1"
    [[ -s "$requirements" ]] || return 0

    local marker_hash marker
    marker_hash="$(sha256sum "$requirements" | awk '{print $1}')"
    marker="${LTX_NODE_DIR}/.requirements-${marker_hash}"

    if [[ ! -f "$marker" ]]; then
        log "Installing Python requirements from: $requirements"
        python -m pip install \
            --disable-pip-version-check \
            --no-cache-dir \
            -r "$requirements"
        rm -f "${LTX_NODE_DIR}"/.requirements-*
        touch "$marker"
    else
        log "LTX Python requirements are already installed"
    fi
}

download_file() {
    local url="$1"
    local destination="$2"
    local minimum_size="$3"
    local directory filename temporary current_size

    directory="$(dirname "$destination")"
    filename="$(basename "$destination")"
    temporary="${destination}.part"
    mkdir -p "$directory"

    if [[ -f "$destination" ]]; then
        current_size="$(stat -c '%s' "$destination" 2>/dev/null || echo 0)"
        if (( current_size >= minimum_size )); then
            log "Cached: ${filename} ($(( current_size / 1073741824 )) GiB)"
            return 0
        fi
        warn "Incomplete final file detected; resuming as .part: $destination"
        if [[ ! -f "$temporary" ]]; then
            mv -f "$destination" "$temporary"
        else
            rm -f "$destination"
        fi
    fi

    log "Downloading: $filename"
    local -a aria_args=(
        --continue=true
        --max-connection-per-server=16
        --split=16
        --min-split-size=16M
        --file-allocation=none
        --auto-file-renaming=false
        --allow-overwrite=true
        --console-log-level=warn
        --summary-interval=10
        --dir="$directory"
        --out="$(basename "$temporary")"
    )

    if [[ -n "${HF_TOKEN:-}" && "$url" == https://huggingface.co/* ]]; then
        aria_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
    fi

    aria2c "${aria_args[@]}" "$url"

    current_size="$(stat -c '%s' "$temporary" 2>/dev/null || echo 0)"
    if (( current_size < minimum_size )); then
        die "Downloaded file is too small: $temporary (${current_size} bytes; expected at least ${minimum_size})"
    fi

    mv -f "$temporary" "$destination"
    log "Downloaded: $destination"
}

install_system_packages
checkout_repo \
    "https://github.com/Lightricks/ComfyUI-LTXVideo.git" \
    "$LTX_NODE_DIR" \
    "$LTX_NODES_REF"
install_python_requirements "$LTX_NODE_DIR/requirements.txt"

# Sanity-check the core nodes required by the official LTX-2.3 workflow.
if [[ ! -f "$COMFYUI_DIR/comfy_extras/nodes_lt_audio.py" ]] || \
   ! grep -Rqs "LatentUpscaleModelLoader" "$COMFYUI_DIR/comfy_extras"; then
    die "This ComfyUI build is too old for the required LTX-2.3 core nodes. Use vastai/comfy:v0.27.0-cuda-12.9-py312 or newer."
fi

# The requested distilled file is a LoRA adapter and must be applied to the full dev checkpoint.
download_file \
    "$BASE_MODEL_URL" \
    "$MODELS_DIR/checkpoints/$BASE_MODEL_NAME" \
    42000000000

download_file \
    "$LORA_URL" \
    "$MODELS_DIR/loras/ltxv/ltx2/$LORA_NAME" \
    7000000000

download_file \
    "$UPSCALER_URL" \
    "$MODELS_DIR/latent_upscale_models/$UPSCALER_NAME" \
    900000000

download_file \
    "$TEXT_ENCODER_URL" \
    "$MODELS_DIR/text_encoders/$TEXT_ENCODER_NAME" \
    12000000000

mkdir -p "$WORKFLOW_DIR"
workflow_source="$(mktemp --tmpdir ltx23-workflow.XXXXXX.json)"
trap 'rm -f "${workflow_source:-}"' EXIT

log "Downloading official two-stage LTX-2.3 workflow"
wget -q --show-progress -O "$workflow_source" "$WORKFLOW_URL"

workflow_destination="$WORKFLOW_DIR/$WORKFLOW_NAME"
python - "$workflow_source" "$workflow_destination" "$TEXT_ENCODER_NAME" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
text_encoder_name = sys.argv[3]

with source.open("r", encoding="utf-8") as fh:
    workflow = json.load(fh)

old_encoder = "comfy_gemma_3_12B_it.safetensors"
replacements = 0


def patch(value):
    global replacements
    if isinstance(value, dict):
        return {key: patch(item) for key, item in value.items()}
    if isinstance(value, list):
        return [patch(item) for item in value]
    if value == old_encoder:
        replacements += 1
        return text_encoder_name
    return value


workflow = patch(workflow)
if replacements == 0:
    raise RuntimeError(f"Text encoder reference {old_encoder!r} was not found in the workflow")

serialized = json.dumps(workflow, ensure_ascii=False)
required = (
    "ltx-2.3-22b-dev.safetensors",
    "ltx-2.3-22b-distilled-lora-384-1.1.safetensors",
    "ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
    text_encoder_name,
)
missing = [item for item in required if item not in serialized]
if missing:
    raise RuntimeError(f"Workflow validation failed; missing references: {missing}")

destination.parent.mkdir(parents=True, exist_ok=True)
temporary = destination.with_suffix(destination.suffix + ".tmp")
with temporary.open("w", encoding="utf-8", newline="\n") as fh:
    json.dump(workflow, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
temporary.replace(destination)
PY

# Also place a copy in the ComfyUI root for Menu -> Load on older frontends.
cp -f "$workflow_destination" "$COMFYUI_DIR/$WORKFLOW_NAME"

log "Model directory usage:"
du -sh "$MODELS_DIR" 2>/dev/null || true
log "Workflow installed: $workflow_destination"
log "Fallback workflow copy: $COMFYUI_DIR/$WORKFLOW_NAME"
log "Provisioning complete. The Vast.ai entrypoint will now start ComfyUI."
