#!/usr/bin/env zsh

# Function to detect the operating system
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "mac";;
        CYGWIN*)    echo "windows";;
        MINGW*)     echo "windows";;
        *)          echo "unknown";;
    esac
}

# Function to get OS-specific package manager command
get_package_manager_install_cmd() {
    local os=$(detect_os)
    case "$os" in
        "linux")
            if command -v apt-get &> /dev/null; then
                echo "sudo apt-get install -y"
            elif command -v dnf &> /dev/null; then
                echo "sudo dnf install -y"
            elif command -v yum &> /dev/null; then
                echo "sudo yum install -y"
            elif command -v pacman &> /dev/null; then
                echo "sudo pacman -S --noconfirm"
            else
                echo "unknown"
            fi
            ;;
        "mac")
            if command -v brew &> /dev/null; then
                echo "brew install"
            else
                echo "unknown"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Function to check if a command exists and suggest installation
check_command() {
    local cmd="$1"
    local package_name="${2:-$1}"  # Use first argument as package name if second is not provided
    
    if ! command -v "$cmd" &> /dev/null; then
        local install_cmd=$(get_package_manager_install_cmd)
        if [ "$install_cmd" = "unknown" ]; then
            echo "🚨 $cmd not found! Please install it manually."
        else
            echo "🚨 $cmd not found! You can install it with: $install_cmd $package_name"
        fi
        return 1
    fi
    return 0
}

# Function to check if Ollama is running
check_ollama_running() {
    if ! curl -s "$KOLLZSH_URL" | grep -q "Ollama is running"; then
        echo "🚨 Ollama server not running at $KOLLZSH_URL!"
        return 1
    fi
    return 0
}

# Function to check if llama.cpp is available (server or CLI)
check_llamacpp_running() {
    local server_url="${KOLLZSH_LLAMACPP_SERVER_URL:-http://localhost:8080}"

    # Check if server is responding
    if curl -s --connect-timeout 2 "${server_url}/health" &> /dev/null; then
        return 0
    fi

    # Server not running - check if we can use CLI mode
    local llama_cli=""
    local llama_path="${KOLLZSH_LLAMACPP_PATH:-}"

    # Look for llama-cli binary
    if [[ -n "$llama_path" ]]; then
        if [[ -x "${llama_path}/llama-cli" ]]; then
            llama_cli="${llama_path}/llama-cli"
        elif [[ -x "${llama_path}/build/bin/llama-cli" ]]; then
            llama_cli="${llama_path}/build/bin/llama-cli"
        fi
    fi

    # Check in PATH
    if [[ -z "$llama_cli" ]] && command -v llama-cli &> /dev/null; then
        llama_cli="llama-cli"
    fi

    if [[ -n "$llama_cli" && -n "$KOLLZSH_LLAMACPP_MODEL" && -f "$KOLLZSH_LLAMACPP_MODEL" ]]; then
        # CLI mode available
        return 0
    fi

    # Neither server nor CLI available
    echo "🚨 llama.cpp not available!"
    echo ""
    echo "Option 1: Start the server"
    echo "  llama-server -m /path/to/model.gguf -c 2048 --port 8080"
    echo ""
    echo "Option 2: Use CLI mode (set these env vars)"
    echo "  export KOLLZSH_LLAMACPP_PATH=/path/to/llama.cpp"
    echo "  export KOLLZSH_LLAMACPP_MODEL=/path/to/model.gguf"
    return 1
}

# Helper function to start llama.cpp server (call manually, not on shell init)
kollzsh-start-llamacpp() {
    local server_url="${KOLLZSH_LLAMACPP_SERVER_URL:-http://localhost:8080}"

    # Check if already running
    if curl -s --connect-timeout 2 "${server_url}/health" &> /dev/null; then
        echo "✅ llama.cpp server already running at ${server_url}"
        return 0
    fi

    # Check if we have a path to start it
    if [[ -z "$KOLLZSH_LLAMACPP_PATH" ]]; then
        echo "🚨 KOLLZSH_LLAMACPP_PATH not set!"
        echo "Set it with: export KOLLZSH_LLAMACPP_PATH=/path/to/llama.cpp"
        return 1
    fi

    local llama_server=""
    # Check for llama-server or llama.cpp server binary
    if [[ -x "${KOLLZSH_LLAMACPP_PATH}/llama-server" ]]; then
        llama_server="${KOLLZSH_LLAMACPP_PATH}/llama-server"
    elif [[ -x "${KOLLZSH_LLAMACPP_PATH}/build/bin/llama-server" ]]; then
        llama_server="${KOLLZSH_LLAMACPP_PATH}/build/bin/llama-server"
    elif [[ -x "${KOLLZSH_LLAMACPP_PATH}/server" ]]; then
        llama_server="${KOLLZSH_LLAMACPP_PATH}/server"
    else
        echo "🚨 Could not find llama-server binary in ${KOLLZSH_LLAMACPP_PATH}"
        return 1
    fi

    if [[ -z "$KOLLZSH_LLAMACPP_MODEL" ]]; then
        echo "🚨 KOLLZSH_LLAMACPP_MODEL not set!"
        echo "Set it with: export KOLLZSH_LLAMACPP_MODEL=/path/to/model.gguf"
        return 1
    fi

    echo "🚀 Starting llama.cpp server..."
    local n_ctx="${KOLLZSH_LLAMACPP_N_CTX:-2048}"
    local n_gpu_layers="${KOLLZSH_LLAMACPP_N_GPU_LAYERS:--1}"
    local port="${server_url##*:}"  # Extract port from URL

    # Start server in background
    nohup "$llama_server" \
        -m "$KOLLZSH_LLAMACPP_MODEL" \
        -c "$n_ctx" \
        -ngl "$n_gpu_layers" \
        --port "$port" \
        > /tmp/kollzsh_llamacpp.log 2>&1 &

    local server_pid=$!
    echo "Server PID: $server_pid"

    # Wait for server to start
    local max_wait=60
    local waited=0
    echo -n "Waiting for server to start"
    while ! curl -s --connect-timeout 1 "${server_url}/health" &> /dev/null; do
        # Check if process is still running
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo ""
            echo "🚨 llama.cpp server process exited!"
            echo "Check logs at: /tmp/kollzsh_llamacpp.log"
            return 1
        fi
        echo -n "."
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $max_wait ]]; then
            echo ""
            echo "🚨 llama.cpp server failed to start within ${max_wait}s"
            echo "Check logs at: /tmp/kollzsh_llamacpp.log"
            return 1
        fi
    done
    echo ""
    echo "✅ llama.cpp server started successfully at ${server_url}"
    return 0
}

# Helper function to stop llama.cpp server
kollzsh-stop-llamacpp() {
    pkill -f "llama-server.*--port" && echo "✅ llama.cpp server stopped" || echo "No llama.cpp server found"
}

# Function to check if vLLM server is running
check_vllm_running() {
    local server_url="${KOLLZSH_VLLM_SERVER_URL:-http://localhost:8000}"

    # Check if server is responding
    if curl -s --connect-timeout 2 "${server_url}/v1/models" &> /dev/null; then
        return 0
    fi

    echo "🚨 vLLM server not running at ${server_url}!"
    echo ""
    echo "Start it with:"
    echo "  vllm serve <model_name> --port 8000"
    echo ""
    echo "Or use the helper function:"
    echo "  kollzsh-start-vllm"
    return 1
}

# Helper function to start vLLM server (call manually, not on shell init)
kollzsh-start-vllm() {
    local server_url="${KOLLZSH_VLLM_SERVER_URL:-http://localhost:8000}"
    local model="${KOLLZSH_VLLM_MODEL:-}"

    # Check if already running
    if curl -s --connect-timeout 2 "${server_url}/v1/models" &> /dev/null; then
        echo "✅ vLLM server already running at ${server_url}"
        return 0
    fi

    # Check if vllm is installed
    if ! command -v vllm &> /dev/null; then
        echo "🚨 vllm not found!"
        echo "Install it with: pip install vllm"
        return 1
    fi

    if [[ -z "$model" ]]; then
        echo "🚨 KOLLZSH_VLLM_MODEL not set!"
        echo "Set it with: export KOLLZSH_VLLM_MODEL=Qwen/Qwen2.5-Coder-3B-Instruct"
        return 1
    fi

    echo "🚀 Starting vLLM server with model: $model"
    local port="${server_url##*:}"  # Extract port from URL

    # Start server in background
    nohup vllm serve "$model" --port "$port" > /tmp/kollzsh_vllm.log 2>&1 &

    local server_pid=$!
    echo "Server PID: $server_pid"

    # Wait for server to start (vLLM can take a while to load models)
    local max_wait=120
    local waited=0
    echo -n "Waiting for server to start (this may take a while)"
    while ! curl -s --connect-timeout 1 "${server_url}/v1/models" &> /dev/null; do
        # Check if process is still running
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo ""
            echo "🚨 vLLM server process exited!"
            echo "Check logs at: /tmp/kollzsh_vllm.log"
            return 1
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge $max_wait ]]; then
            echo ""
            echo "🚨 vLLM server failed to start within ${max_wait}s"
            echo "Check logs at: /tmp/kollzsh_vllm.log"
            return 1
        fi
    done
    echo ""
    echo "✅ vLLM server started successfully at ${server_url}"
    return 0
}

# Helper function to stop vLLM server
kollzsh-stop-vllm() {
    pkill -f "vllm serve" && echo "✅ vLLM server stopped" || echo "No vLLM server found"
}

# Function to check if Claude Code backend is available
check_claude_server() {
    local server_url="${KOLLZSH_CLAUDE_BASE_URL:-}"

    # No custom base URL = using Anthropic API directly, just check claude CLI exists
    if [[ -z "$server_url" ]]; then
        return 0
    fi

    # Custom base URL configured — check if the local server is responding
    if curl -s --connect-timeout 2 "${server_url}/v1/models" &> /dev/null; then
        return 0
    fi

    echo "🚨 Local model server not running at ${server_url}!"
    echo ""
    echo "Start the server and load model: ${KOLLZSH_CLAUDE_MODEL}"
    echo ""
    echo "Or switch to Anthropic API directly:"
    echo "  export KOLLZSH_CLAUDE_BASE_URL=''"
    echo "  export KOLLZSH_CLAUDE_MODEL=sonnet"
    return 1
}
