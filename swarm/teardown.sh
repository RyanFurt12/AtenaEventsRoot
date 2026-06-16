#!/usr/bin/env bash
# Remove a stack e derruba o cluster DinD (com volumes). Não afeta o dev.
# Uso: bash swarm/teardown.sh
set -euo pipefail

SWARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker exec manager docker stack rm atena 2>/dev/null || true
docker compose -f "$SWARM_DIR/dind-cluster.yml" down -v

echo "Cluster removido."
