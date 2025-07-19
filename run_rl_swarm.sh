#!/bin/bash

set -euo pipefail

# ==================== HÀM HIỂN THỊ BANNER ====================
show_banner() {
    tput reset 2>/dev/null || clear
    echo -e "\033[38;5;224m"
    cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn
EOF
    echo -e "\033[0m"
    echo "=================================================================================="
    echo ""
}

# ==================== HÀM CHẠY LỆNH VỚI BANNER ====================
run_with_banner() {
    show_banner
    echo -e "\033[1;34m▶ Đang chạy: $*\033[0m\n"
    local start_time end_time elapsed
    start_time=$(date +%s)
    
    "$@" || {
        echo -e "\n\033[1;31m✗ Lệnh thất bại: $*\033[0m"
        return 1
    }
    
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    echo -e "\n\033[1;32m✓ Hoàn thành sau ${elapsed}s: $*\033[0m"
    return 0
}

# ==================== MAIN SCRIPT ====================

# Hiển thị banner lần đầu
show_banner

# General arguments
ROOT=$PWD
GENRL_TAG="v0.1.1"

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export HUGGINGFACE_ACCESS_TOKEN="None"

# Path to an RSA private key
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

# Bit of a workaround for the non-root docker container.
if [ -n "$DOCKER" ]; then
    volumes=(
        /home/gensyn/rl_swarm/modal-login/temp-data
        /home/gensyn/rl_swarm/keys
        /home/gensyn/rl_swarm/configs
        /home/gensyn/rl_swarm/logs
    )

    for volume in ${volumes[@]}; do
        sudo chown -R 1001:1001 $volume
    done
fi

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-""}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Function to clean up the server process upon exit
cleanup() {
    show_banner
    echo_green ">> Shutting down trainer..."

    # Remove modal credentials if they exist
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true

    # Kill all processes belonging to this script's process group
    kill -- -$$ || true

    exit 0
}

errnotify() {
    show_banner
    echo_red ">> An error was detected while running rl-swarm. See $ROOT/logs for full logs."
}

trap cleanup EXIT
trap errnotify ERR

# Create logs directory if it doesn't exist
run_with_banner mkdir -p "$ROOT/logs"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server.
    run_with_banner echo "Please login to create an Ethereum Server Wallet"
    run_with_banner cd modal-login
    
    # Node.js + NVM setup
    if ! command -v node > /dev/null 2>&1; then
        run_with_banner echo "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            run_with_banner curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        run_with_banner nvm install node
    else
        run_with_banner echo "Node.js is already installed: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
        if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
            run_with_banner echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
            run_with_banner curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            run_with_banner echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            run_with_banner sudo apt update && sudo apt install -y yarn
        else
            run_with_banner echo "Yarn not found. Installing Yarn globally with npm (no profile edits)…"
            run_with_banner npm install -g --silent yarn
        fi
    fi

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        run_with_banner sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        run_with_banner sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi

    # Docker image already builds it, no need to again.
    if [ -z "$DOCKER" ]; then
        run_with_banner yarn install --immutable
        run_with_banner echo "Building server"
        run_with_banner yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi
    
    run_with_banner yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
    SERVER_PID=$!
    run_with_banner echo "Started server process: $SERVER_PID"
    run_with_banner sleep 5

    # Local tunnel implementation
    run_with_banner echo ">> Setting up localtunnel..."
    
    if ! command -v lt > /dev/null 2>&1; then
        run_with_banner npm install -g localtunnel
    fi

    run_with_banner echo "Getting tunnel password..."
    TUNNEL_PASSWORD=$(curl -s https://loca.lt/mytunnelpassword)
    run_with_banner echo "Tunnel password: $TUNNEL_PASSWORD"

    run_with_banner lt --port 3000 > "$ROOT/logs/localtunnel.log" 2>&1 &
    TUNNEL_PID=$!
    run_with_banner sleep 5

    TUNNEL_URL=$(grep -o 'https://[^ ]*\.loca\.lt' "$ROOT/logs/localtunnel.log" | tail -n1)

    if [ -n "$TUNNEL_URL" ]; then
        # Make URL clickable
        run_with_banner echo -e "${GREEN_TEXT}>> Public URL: \e]8;;$TUNNEL_URL\a$TUNNEL_URL\e]8;;\a${RESET_TEXT}"
        echo "$TUNNEL_URL" > "$ROOT/localtunnel.url"
        
        if [ -z "$DOCKER" ]; then
            if command -v xdg-open > /dev/null; then
                xdg-open "$TUNNEL_URL" >/dev/null 2>&1 &
            elif command -v open > /dev/null; then
                open "$TUNNEL_URL" >/dev/null 2>&1 &
            fi
        fi
    else
        run_with_banner echo_red ">> Failed to get tunnel URL. Using localhost instead."
        TUNNEL_URL="http://localhost:3000"
    fi

    run_with_banner cd ..

    run_with_banner echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        run_with_banner sleep 5
    done
    run_with_banner echo "Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    run_with_banner echo "Your ORG_ID is set to: $ORG_ID"

    run_with_banner echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            run_with_banner echo "API key is activated! Proceeding..."
            break
        else
            run_with_banner echo "Waiting for API key to be activated..."
            run_with_banner sleep 5
        fi
    done
fi

run_with_banner echo_green ">> Getting requirements..."
run_with_banner pip install --upgrade pip

run_with_banner pip install gensyn-genrl==0.1.4
run_with_banner pip install reasoning-gym>=0.1.20
run_with_banner pip install trl
run_with_banner pip install hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd

if [ ! -d "$ROOT/configs" ]; then
    run_with_banner mkdir "$ROOT/configs"
fi  

if [ -f "$ROOT/configs/rg-swarm.yaml" ]; then
    if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            run_with_banner echo_green ">> Found differences in rg-swarm.yaml. If you would like to reset to the default, set GENSYN_RESET_CONFIG to a non-empty value."
        else
            run_with_banner echo_green ">> Found differences in rg-swarm.yaml. Backing up existing config."
            run_with_banner mv "$ROOT/configs/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml.bak"
            run_with_banner cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
        fi
    fi
else
    run_with_banner cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    run_with_banner sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

run_with_banner echo_green ">> Done!"

HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    show_banner
    echo -en $GREEN_TEXT
    read -p ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
    echo -en $RESET_TEXT
    yn=${yn:-N}
    case $yn in
        [Yy]*) 
            show_banner
            read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN 
            ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) 
            show_banner
            echo ">>> No answer was given, so NO models will be pushed to Hugging Face Hub" 
            HUGGINGFACE_ACCESS_TOKEN="None" 
            ;;
    esac
fi

show_banner
echo -en $GREEN_TEXT
read -p ">> Enter the name of the model you want to use in huggingface repo/name format, or press [Enter] to use the default model. " MODEL_NAME
echo -en $RESET_TEXT

if [ -n "$MODEL_NAME" ]; then
    export MODEL_NAME
    run_with_banner echo_green ">> Using model: $MODEL_NAME"
else
    run_with_banner echo_green ">> Using default model from config"
fi

show_banner
run_with_banner echo_green ">> Good luck in the swarm!"
run_with_banner echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

run_with_banner python -m rgym_exp.runner.swarm_launcher \
    --config-path "$ROOT/rgym_exp/config" \
    --config-name "rg-swarm.yaml" 

wait
