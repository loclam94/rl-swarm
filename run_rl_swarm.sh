#!/bin/bash

# Clear terminal and position cursor at top
clear
echo -ne "\033[H"

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
    echo_green ">> Shutting down trainer..."

    # Remove modal credentials if they exist
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true

    # Kill all processes belonging to this script's process group
    kill -- -$$ || true

    exit 0
}

errnotify() {
    echo_red ">> An error was detected while running rl-swarm. See $ROOT/logs for full logs."
}

trap cleanup EXIT
trap errnotify ERR

# Display banner with gradient color
echo -e "\033[38;5;39m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██
EOF
echo -e "\n"  # Xuống 1 dòng trống
# Display custom text with blink effect and gradient color
echo -ne "\033[5m"  # Enable blink effect
echo -ne "\033[38;5;39mB\033[38;5;45my\033[38;5;51m \033[38;5;87mP\033[38;5;129mi\033[38;5;93mz\033[38;5;99m \033[38;5;105m-\033[38;5;111m \033[38;5;117mT\033[38;5;123mG\033[38;5;129m:\033[38;5;135m \033[38;5;141mh\033[38;5;147mt\033[38;5;153mt\033[38;5;159mp\033[38;5;165ms\033[38;5;171m:\033[38;5;177m/\033[38;5;183m/\033[38;5;189mt\033[38;5;195m.\033[38;5;201mm\033[38;5;207me\033[38;5;213m/\033[38;5;219mN\033[38;5;225me\033[38;5;231mx\033[38;5;39mg\033[38;5;45me\033[38;5;51mn\033[38;5;87mg\033[38;5;129me\033[38;5;93mn\033[38;5;99mp\033[38;5;105ml\033[38;5;111mo\033[38;5;117mr\033[38;5;123me"
echo -e "\033[0m"  # Reset all attributes
echo -e "\n"  # Xuống 1 dòng trống
# Create logs directory if it doesn't exist
mkdir -p "$ROOT/logs"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server.
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login
    
    # Node.js + NVM setup
    if ! command -v node > /dev/null 2>&1; then
        echo "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install node
    else
        echo "Node.js is already installed: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        echo "Yarn not found. Installing Yarn..."
        npm install -g yarn
    fi

    # Docker image already builds it, no need to again.
    if [ -z "$DOCKER" ]; then
        yarn install --immutable
        echo "Building server"
        yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi
    
    yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
    SERVER_PID=$!
    echo "Started server process: $SERVER_PID"
    sleep 5

    # Local tunnel implementation
    echo ">> Setting up localtunnel..."
    
    if ! command -v lt > /dev/null 2>&1; then
        npm install -g localtunnel
    fi

    echo "Getting tunnel password..."
    TUNNEL_PASSWORD=$(curl -s https://loca.lt/mytunnelpassword)
    echo "Tunnel password: $TUNNEL_PASSWORD"

    lt --port 3000 > "$ROOT/logs/localtunnel.log" 2>&1 &
    TUNNEL_PID=$!
    sleep 5

    TUNNEL_URL=$(grep -o 'https://[^ ]*\.loca\.lt' "$ROOT/logs/localtunnel.log" | tail -n1)

    if [ -n "$TUNNEL_URL" ]; then
        echo -e "${GREEN_TEXT}>> Public URL: $TUNNEL_URL${RESET_TEXT}"
        echo "$TUNNEL_URL" > "$ROOT/localtunnel.url"
        
        if [ -z "$DOCKER" ]; then
            if command -v xdg-open > /dev/null; then
                xdg-open "$TUNNEL_URL" >/dev/null 2>&1 &
            elif command -v open > /dev/null; then
                open "$TUNNEL_URL" >/dev/null 2>&1 &
            fi
        fi
    else
        echo_red ">> Failed to get tunnel URL. Using localhost instead."
        TUNNEL_URL="http://localhost:3000"
    fi

    cd ..

    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5
    done
    echo "Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key is activated! Proceeding..."
            break
        else
            echo "Waiting for API key to be activated..."
            sleep 5
        fi
    done
fi

echo_green ">> Getting requirements..."
pip install --upgrade pip

pip install gensyn-genrl==0.1.4
pip install reasoning-gym>=0.1.20
pip install trl
pip install hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd

if [ ! -d "$ROOT/configs" ]; then
    mkdir "$ROOT/configs"
fi  

if [ -f "$ROOT/configs/rg-swarm.yaml" ]; then
    if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            echo_green ">> Found differences in rg-swarm.yaml. If you would like to reset to the default, set GENSYN_RESET_CONFIG to a non-empty value."
        else
            echo_green ">> Found differences in rg-swarm.yaml. Backing up existing config."
            mv "$ROOT/configs/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml.bak"
            cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
        fi
    fi
else
    cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

echo_green ">> Done!"

HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -en $GREEN_TEXT
    read -p ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
    echo -en $RESET_TEXT
    case $yn in
        [Yy]*) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

echo -en $GREEN_TEXT
read -p ">> Enter the name of the model you want to use in huggingface repo/name format, or press [Enter] to use the default model. " MODEL_NAME
echo -en $RESET_TEXT

if [ -n "$MODEL_NAME" ]; then
    export MODEL_NAME
    echo_green ">> Using model: $MODEL_NAME"
else
    echo_green ">> Using default model from config"
fi

echo_green ">> Good luck in the swarm!"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

# Launch the swarm
python -m rgym_exp.runner.swarm_launcher \
    --config-path "$ROOT/rgym_exp/config" \
    --config-name "rg-swarm.yaml"

wait
