#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONTAINER_NAME="sofa-doc"

# If container is already running: attach to it
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Attaching to running container: ${CONTAINER_NAME}"
    docker exec -it \
        -e CLAUDE_CONFIG_DIR=/root/.claude \
        "$CONTAINER_NAME" \
        claude
    exit 0
fi

# If container exists but is stopped: start and attach
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Starting existing container: ${CONTAINER_NAME}"
    docker start "$CONTAINER_NAME" >/dev/null
    docker exec -it \
        -e CLAUDE_CONFIG_DIR=/root/.claude \
        "$CONTAINER_NAME" \
        claude
    exit 0
fi

# Otherwise create a new container
docker run -it --rm --name "$CONTAINER_NAME" \
    --env-file "$ENV_FILE" \
    -e CLAUDE_CONFIG_DIR=/root/.claude \
    -v "$(pwd)":/workspace \
    -v "./.claude-config":/root/.claude \
    claude-code claude
