#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

APT_PACKAGES=(
    "aria2"
    "ffmpeg"
)

PIP_PACKAGES=(
    # "package"
)

NODES=(
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
)

CHECKPOINT_MODELS=(
    # handled via aria2c below (too large for single-thread wget)
)

UNET_MODELS=()
LORA_MODELS=()
VAE_MODELS=()
ESRGAN_MODELS=()
CONTROLNET_MODELS=()

# Custom URLs for aria2c parallel download
WAN22_CHECKPOINT_URL="https://huggingface.co/Phr00t/WAN2.2-14B-Rapid-AllInOne/resolve/main/Mega-v12/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors"
CLIP_VISION_URL="https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
WORKFLOW_URL="https://raw.githubusercontent.com/xtclovver/StartUPConfigsAI/refs/heads/main/comfy_wf_wan2.2-ti2v-aio_uncensored.json"

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages

    # Large models via aria2c (16 parallel connections, much faster than wget)
    provisioning_get_model_aria2c \
        "${COMFYUI_DIR}/models/checkpoints/wan2.2-rapid-mega-aio-nsfw-v12.2.safetensors" \
        "$WAN22_CHECKPOINT_URL" \
        20000000000

    provisioning_get_model_aria2c \
        "${COMFYUI_DIR}/models/clip_vision/clip_vision_h.safetensors" \
        "$CLIP_VISION_URL" \
        3000000000

    # Download workflow
    provisioning_get_workflow

    provisioning_print_end
}

# Download with aria2c, skip if already cached (checks min file size in bytes)
function provisioning_get_model_aria2c() {
    local dest="$1"
    local url="$2"
    local min_bytes="${3:-0}"
    local dest_dir
    dest_dir=$(dirname "$dest")
    local filename
    filename=$(basename "$dest")

    mkdir -p "$dest_dir"

    if [[ -f "$dest" ]]; then
        local sz
        sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [[ "$sz" -ge "$min_bytes" ]]; then
            printf "Cached: %s (%d GB)\n" "$filename" "$(( sz / 1073741824 ))"
            return 0
        fi
        rm -f "$dest"
    fi

    printf "Downloading: %s\n" "$filename"

    local aria_args=(-x 16 -s 16 -k 1M --console-log-level=warn
        -d "$dest_dir" -o "$filename")

    # Inject HF token if URL matches huggingface.co
    if [[ -n "${HF_TOKEN:-}" && "$url" =~ huggingface\.co ]]; then
        aria_args+=(--header="Authorization: Bearer ${HF_TOKEN}")
    fi

    aria2c "${aria_args[@]}" "$url" || { printf "ERROR: Failed to download %s\n" "$filename"; return 1; }
}

function provisioning_get_workflow() {
    local dest="${COMFYUI_DIR}/workflow_wan22_i2v.json"
    printf "Downloading workflow...\n"
    wget -q -O "$dest" "$WORKFLOW_URL" && printf "Workflow saved: %s\n" "$dest" \
        || printf "WARNING: Workflow download failed\n"
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        apt-get install -y "${APT_PACKAGES[@]}"
    fi
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
        pip install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                    pip install --no-cache-dir -r "$requirements"
                fi
            fi
        else
            printf "Downloading node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
            if [[ -e $requirements ]]; then
                pip install --no-cache-dir -r "${requirements}"
            fi
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi
    dir="$1"; mkdir -p "$dir"; shift; arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete: Application will start now\n"
    printf "Workflow: Menu -> Load -> workflow_wan22_i2v.json\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "$HF_TOKEN" ]] || return 1
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "https://huggingface.co/api/whoami-v2" \
        -H "Authorization: Bearer $HF_TOKEN" -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "https://civitai.com/api/v1/models?hidden=1&limit=1" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

function provisioning_download() {
    local auth_token=""
    if [[ -n "${HF_TOKEN:-}" && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n "${CIVITAI_TOKEN:-}" && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    if [[ -n $auth_token ]]; then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    fi
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
