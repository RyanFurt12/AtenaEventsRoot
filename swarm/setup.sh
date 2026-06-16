#!/usr/bin/env bash
# Sobe o cluster DinD, carrega as imagens nos nós, inicializa o Swarm e
# implanta a stack. Idempotente.
set -euo pipefail

SWARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SWARM_DIR/.." && pwd)"
CLUSTER="$SWARM_DIR/dind-cluster.yml"
STACK="$SWARM_DIR/docker-stack.yml"
NODES="manager worker1 worker2"

log() { printf '\n==> %s\n' "$*"; }

# Carrega o .env da raiz
if [ -f "$ROOT/.env" ]; then
  log "Lendo configuração de $ROOT/.env"
  set -a; . "$ROOT/.env"; set +a
else
  log "AVISO: $ROOT/.env não encontrado — usando defaults"
fi

# Extrai a porta de uma URL ($1 = url, $2=fallback value)
extract_port() {
  local p; p="$(printf '%s' "$1" | sed -nE 's#^[a-z]+://[^/:]+:([0-9]+).*#\1#p')"
  printf '%s' "${p:-$2}"
}
WEB_PORT="$(extract_port "${FRONTEND_URL:-}" 3000)"
API_PORT="$(extract_port "${API_URL:-}" 8080)"
VIZ_PORT="${VIZ_PORT:-8088}"
MAILHOG_PORT="${MAILHOG_PORT:-8025}"

# Defaults para o que não estiver no .env
export POSTGRES_DB="${POSTGRES_DB:-atena_events}"
export POSTGRES_USER="${POSTGRES_USER:-atena}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-atena_secret}"
export JWT_SECRET="${JWT_SECRET:-troque_esta_chave_para_no_minimo_32_caracteres}"
export API_URL="${API_URL:-http://localhost:8080}"
export FRONTEND_URL="${FRONTEND_URL:-http://localhost:3000}"
export WEB_PORT API_PORT VIZ_PORT MAILHOG_PORT

log "Portas: web=$WEB_PORT | api=$API_PORT | visualizer=$VIZ_PORT | mailhog=$MAILHOG_PORT"

log "Subindo os nós DinD"
docker compose -f "$CLUSTER" up -d

wait_daemon() {
  log "Aguardando o daemon do nó '$1'"
  until docker exec "$1" docker info >/dev/null 2>&1; do printf '.'; sleep 2; done
}
for node in $NODES; do wait_daemon "$node"; done

log "Buildando as imagens no host"
docker build -t atena-api:latest "$ROOT/AtenaEventsAPI"
docker build --build-arg VITE_API_URL="$API_URL" \
  -t atena-web:latest "$ROOT/AtenaEventsWeb"

for img in atena-api:latest atena-web:latest; do
  for node in $NODES; do
    log "Carregando $img em '$node'"
    docker save "$img" | docker exec -i "$node" docker load
  done
done

if [ "$(docker exec manager docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
  MANAGER_IP="$(docker exec manager hostname -i | awk '{print $1}')"
  log "Inicializando o Swarm (manager $MANAGER_IP)"
  docker exec manager docker swarm init --advertise-addr "$MANAGER_IP"
fi

MANAGER_IP="$(docker exec manager hostname -i | awk '{print $1}')"
JOIN_TOKEN="$(docker exec manager docker swarm join-token -q worker)"
for node in worker1 worker2; do
  if [ "$(docker exec "$node" docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
    log "Worker '$node' entrando no cluster"
    docker exec "$node" docker swarm join --token "$JOIN_TOKEN" "$MANAGER_IP:2377"
  fi
done

if ! docker exec manager docker config inspect atena_dbinit >/dev/null 2>&1; then
  log "Criando config atena_dbinit a partir do db-init.sql"
  docker exec -i manager docker config create atena_dbinit - < "$ROOT/db-init.sql"
fi

log "Implantando a stack 'atena'"
docker cp "$STACK" manager:/docker-stack.yml
docker exec \
  -e WEB_PORT="$WEB_PORT" -e API_PORT="$API_PORT" -e VIZ_PORT="$VIZ_PORT" \
  -e MAILHOG_PORT="$MAILHOG_PORT" \
  -e POSTGRES_DB="$POSTGRES_DB" -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" -e JWT_SECRET="$JWT_SECRET" \
  -e API_URL="$API_URL" -e FRONTEND_URL="$FRONTEND_URL" \
  manager docker stack deploy --resolve-image never -c /docker-stack.yml atena

log "Nós do cluster (aguarde)"
docker exec manager docker node ls
log "Serviços (aguarde)"
docker exec manager docker service ls

printf '\nPronto. Web: http://localhost:%s | API: http://localhost:%s | Visualizer: http://localhost:%s | MailHog: http://localhost:%s\n' "$WEB_PORT" "$API_PORT" "$VIZ_PORT" "$MAILHOG_PORT"
printf 'Ex: Variar réplicas: docker exec manager docker service scale atena_api=5\n'
printf 'Encerrar: bash swarm/teardown.sh\n'
