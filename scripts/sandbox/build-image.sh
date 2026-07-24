#!/usr/bin/env bash
# Build the Sysbox sibling sandbox image (nested Docker + Compose).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE="${OPENCODE_SANDBOX_IMAGE:-opencode-sandbox:local}"

cd "$REPO_ROOT"
echo "Building ${IMAGE} from docker/sandbox/Dockerfile ..."
docker build -t "$IMAGE" -f docker/sandbox/Dockerfile docker/sandbox
echo "Done: ${IMAGE}"
