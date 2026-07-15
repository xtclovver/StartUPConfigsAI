#!/bin/bash
# =============================================================================
# ComfyUI + WAN 2.2 Rapid Mega AIO NSFW v12.2 (VACE workflow) — Vast.ai
# Template: vastai/comfy (Cuda 12.9, SSH, Jupyter)
# Persistent storage: /workspace
# On-start Script: paste this entire file
# =============================================================================

# Run everything in background so ComfyUI template can start independently
(
set -euo pipefail

COMFY_DIR="/workspace/ComfyUI"
VOLUME_DIR="/workspace/models"

CHECKPOINT_URL="https://huggingface.co/Phr00t/WAN2.2-14B-Rapid-AllInOne/resolve/main/Mega-v12/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors?download=true"
WORKFLOW_URL="https://raw.githubusercontent.com/xtclovver/StartUPConfigsAI/refs/heads/main/Rapid-AIO-Mega-v12_SA.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $1"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $1"; exit 1; }

START_TIME=$(date +%s)

# --- GPU check ---
log "Checking GPU..."
command -v nvidia-smi &>/dev/null || err "nvidia-smi not found."
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# --- Verify ComfyUI exists (template should have it) ---
if [ ! -d "$COMFY_DIR" ]; then
    warn "ComfyUI not found at ${COMFY_DIR}, cloning..."
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
    cd "$COMFY_DIR"
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
else
    log "ComfyUI found at ${COMFY_DIR}"
    cd "$COMFY_DIR" && git pull --ff-only 2>/dev/null || true
fi

# --- Install system deps if missing ---
command -v aria2c &>/dev/null || {
    log "Installing aria2..."
    apt-get update -qq && apt-get install -y -qq aria2 > /dev/null 2>&1
}

# --- Custom nodes ---
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"

install_node() {
    local repo="$1"
    local dir="${CUSTOM_NODES}/${repo##*/}"
    if [ ! -d "$dir" ]; then
        log "Installing ${repo##*/}..."
        git clone --depth 1 "$repo" "$dir"
    else
        log "${repo##*/} already installed, updating..."
        ( cd "$dir" && git pull --ff-only 2>/dev/null || true )
    fi
    [ -f "$dir/requirements.txt" ] && pip install -r "$dir/requirements.txt" -q || true
}

install_node "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
install_node "https://github.com/kijai/ComfyUI-WanVideoWrapper"
install_node "https://github.com/kijai/ComfyUI-KJNodes"

# --- Create model dirs on persistent volume ---
mkdir -p "${VOLUME_DIR}/checkpoints"
log "Models volume: ${VOLUME_DIR}"

# --- Download models ---
download_model() {
    local url="$1" dest="$2" min_bytes="$3"
    if [ -f "$dest" ]; then
        local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [ "$sz" -ge "$min_bytes" ]; then
            log "  Cached: $(basename $dest) ($(( sz / 1073741824 )) GB)"
            return 0
        fi
        rm -f "$dest"
    fi
    log "  Downloading: $(basename $dest)..."
    local aria_args=(-x 16 -s 16 -k 1M --console-log-level=warn
        -d "$(dirname $dest)" -o "$(basename $dest)")
    if [[ -n "${HF_TOKEN:-}" && "$url" =~ huggingface\.co ]]; then
        aria_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
    fi
    aria2c "${aria_args[@]}" "$url"
}

log "Downloading models..."
download_model "$CHECKPOINT_URL" \
    "${VOLUME_DIR}/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors" 20000000000

# --- Symlink models into ComfyUI ---
log "Linking models..."
mkdir -p "${COMFY_DIR}/models/checkpoints"
ln -sf "${VOLUME_DIR}/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors" \
    "${COMFY_DIR}/models/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors"

# --- Download workflow ---
log "Downloading workflow..."
wget -q -O "${COMFY_DIR}/Rapid-AIO-Mega-v12_SA.json" "$WORKFLOW_URL" || err "Workflow download failed"

END_TIME=$(date +%s)
log "Setup done in $((END_TIME - START_TIME))s"
log ""
log "Models stored at: ${VOLUME_DIR} (persists across restarts)"
log "ComfyUI port:     8188 (open via Vast.ai port forwarding or SSH tunnel)"
log "SSH tunnel:       ssh -L 8188:localhost:8188 root@<host> -p <port>"
log "Workflow:         Menu -> Load -> Rapid-AIO-Mega-v12_SA.json"
log ""
log "If ComfyUI is not running, start manually:"
log "  cd ${COMFY_DIR} && python3 main.py --listen 0.0.0.0 --port 8188 --highvram --gpu-only --disable-auto-launch"

) >> /var/log/comfyui_setup.log 2>&1 &

echo "[setup] Running in background. Tail logs: tail -f /var/log/comfyui_setup.log"
