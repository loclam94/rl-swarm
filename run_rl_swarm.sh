#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

# GenRL Swarm version to use
GENRL_TAG="v0.1.1"

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export HUGGINGFACE_ACCESS_TOKEN="None"
export SKIP_LOCALTUNNEL=${SKIP_LOCALTUNNEL:-""}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
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

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF

# Create logs directory if it doesn't exist
mkdir -p "$ROOT/logs"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server.
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login
    
    # Fix npm peer dependencies before installation
    echo "Fixing npm peer dependencies..."
    npm config set legacy-peer-deps true
    npm config set fund false
    
    # Node.js + NVM setup
    if ! command -v node > /dev/null 2>&1; then
        echo "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install --lts
    else
        echo "Node.js is already installed: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        echo "Yarn not found. Installing Yarn..."
        npm install -g yarn
    fi

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi

    # Install dependencies with forced continuation on warnings
    echo "Installing dependencies..."
    yarn install --ignore-engines --network-timeout 300000 > "$ROOT/logs/yarn-install.log" 2>&1 || {
        echo_red ">> Yarn install encountered warnings but continuing anyway"
    }

    echo "Building server"
    yarn build > "$ROOT/logs/yarn-build.log" 2>&1
    
    echo "Starting server..."
    yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
    SERVER_PID=$!
    echo "Started server process: $SERVER_PID"
    sleep 5

    # Local tunnel implementation with multiple fallbacks
    if [ -z "$SKIP_LOCALTUNNEL" ]; then
        echo_green ">> Setting up public URL..."
        
        # Try localtunnel first
        if command -v lt > /dev/null 2>&1; then
            echo "Attempting localtunnel..."
            LT_OUTPUT=$(timeout 15 lt --port 3000 --print-requests 2>&1) && {
                TUNNEL_URL=$(echo "$LT_OUTPUT" | grep -o 'https://[^ ]*\.localtunnel\.me' | head -n1)
                [ -n "$TUNNEL_URL" ] && {
                    echo_green ">> Local tunnel URL: $TUNNEL_URL"
                    PUBLIC_URL=$TUNNEL_URL
                }
            }
        fi

        # Fallback to ngrok if available
        if [ -z "$PUBLIC_URL" ] && command -v ngrok > /dev/null 2>&1; then
            echo "Attempting ngrok..."
            NGROK_OUTPUT=$(timeout 15 ngrok http 3000 2>&1) && {
                NGROK_URL=$(echo "$NGROK_OUTPUT" | grep -o 'https://[^ ]*\.ngrok\.io' | head -n1)
                [ -n "$NGROK_URL" ] && {
                    echo_green ">> Ngrok URL: $NGROK_URL"
                    PUBLIC_URL=$NGROK_URL
                }
            }
        fi

        # Final fallback to localhost
        if [ -z "$PUBLIC_URL" ]; then
            echo_red ">> Failed to establish public URL. Using localhost."
            PUBLIC_URL="http://localhost:3000"
        fi
    else
        echo_blue ">> Skipping public URL setup as requested"
        PUBLIC_URL="http://localhost:3000"
    fi

    # Open browser if not in docker
    if [ -z "$DOCKER" ]; then
        if command -v xdg-open > /dev/null; then
            xdg-open "$PUBLIC_URL" >/dev/null 2>&1 &
        elif command -v open > /dev/null; then
            open "$PUBLIC_URL" >/dev/null 2>&1 &
        fi
    fi

    cd ..

    echo_green ">> Waiting for modal userData.json..."
    timeout 300 bash -c "while [ ! -f 'modal-login/temp-data/userData.json' ]; do sleep 5; done" || {
        echo_red ">> Timed out waiting for userData.json"
        exit 1
    }
    
    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    # Wait for API key activation
    echo "Waiting for API key activation..."
    timeout 300 bash -c "while [[ \"$(curl -s http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID)\" != \"activated\" ]]; do sleep 5; done" || {
        echo_red ">> Timed out waiting for API key activation"
        exit 1
    }
    echo "API key activated!"
fi

# ... (phần còn lại của script giữ nguyên từ phần cài đặt pip trở đi)
