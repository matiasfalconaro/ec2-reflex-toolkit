#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-"$(cd "$SCRIPT_DIR/../.." && pwd)"}"
RUN_CONFIG="${RUN_CONFIG:-$REPO_ROOT/.run.local.env}"

IMAGE=""
IMAGE_NAME=""

load_config() {
    if [[ -f "$RUN_CONFIG" ]]; then
        set -a
        . "$RUN_CONFIG"
        set +a
    fi
}

run_container() {
    local image="${1:-${IMAGE:-your-registry/your-image:latest}}"
    local container_name="${2:-${IMAGE_NAME:-image-name}}"
    local frontend_port="${3:-3000}"
    local backend_port="${4:-8000}"
    
    IMAGE="$image"
    IMAGE_NAME="$container_name"
    
    echo "Pulling image: $IMAGE"
    sudo /usr/bin/docker pull "$IMAGE"
    
    echo "Removing existing container: $container_name"
    sudo /usr/bin/docker rm -f "$container_name" 2>/dev/null || true
    
    echo "Starting container: $container_name"
    sudo /usr/bin/docker run -d \
        --name "$container_name" \
        --restart=always \
        -p "127.0.0.1:${frontend_port}:3000" \
        -p "127.0.0.1:${backend_port}:8000" \
        "$IMAGE" \
        reflex run --env prod --frontend-port 3000 --backend-host 0.0.0.0 --backend-port 8000
}

wait_for_frontend() {
    local max_attempts=60
    local attempt=1
    
    echo -n "Connecting to frontend..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s --max-time 2 http://127.0.0.1:3000/ >/dev/null 2>&1; then
            echo -e "\rFrontend OK            "
            return 0
        fi
        
        if [[ $attempt -eq $max_attempts ]]; then
            echo -e "\nERROR: Frontend did not respond in ${max_attempts}s (http://127.0.0.1:3000/)."
            sudo docker logs --tail 100 "$IMAGE_NAME" || true
            return 1
        fi
        
        sleep 1
        ((attempt++))
    done
}

show_container_status() {
    echo "Container status:"
    sudo /usr/bin/docker ps --filter name="$IMAGE_NAME"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    local image="${1:-${IMAGE:-your-registry/your-image:latest}}"
    
    echo "Checking Docker accessibility..."
    if ! sudo docker info >/dev/null 2>&1; then
        echo "WARNING: Docker info check failed, but attempting to continue..."
        echo "Trying to start Docker service..."
        sudo systemctl start docker || true
        sleep 2
        
        if ! sudo docker info >/dev/null 2>&1; then
            echo "ERROR: Docker not accessible after retry" >&2
            exit 1
        fi
    fi
    
    load_config
    run_container "$image"
    wait_for_frontend || exit 1
    show_container_status
    
    echo "Deployment completed successfully!"
fi
