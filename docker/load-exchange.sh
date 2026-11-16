#!/usr/bin/env bash
# Carga no Exchange pelo gateway, para medir o cache Redis (docs/gargalos/cache-redis.md).
# Faz login como admin e dispara requisições de cotação com o hey, em container na rede do compose.
#
#   ADMIN_EMAIL=... ADMIN_PASSWORD=... ./docker/load-exchange.sh [requisições] [concorrência] [par]
#   ex.: ./docker/load-exchange.sh 300 10 USD/BRL
#
# Mantenha a carga moderada: sem cache, cada requisição vai até a AwesomeAPI (API pública).
#
# No kind (k8s/README.md): NETWORK=kind GATEWAY_INTERNAL=http://pma26-control-plane:30080 ./docker/load-exchange.sh
set -eu

N="${1:-300}"
C="${2:-10}"
PAIR="${3:-USD/BRL}"
# GATEWAY: endereço visto da sua máquina (login); GATEWAY_INTERNAL: visto pelo container do hey
GATEWAY="${GATEWAY:-http://localhost:8080}"
NETWORK="${NETWORK:-pma26_default}"
GATEWAY_INTERNAL="${GATEWAY_INTERNAL:-http://gateway:8080}"
# sem as variáveis no terminal, lê o login do admin direto do docker/.env
ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env"
if [ -z "${ADMIN_EMAIL:-}" ] && [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi
: "${ADMIN_EMAIL:?defina ADMIN_EMAIL (ou crie docker/.env)}" "${ADMIN_PASSWORD:?defina ADMIN_PASSWORD (ou crie docker/.env)}"

TOKEN="$(curl -s -X POST "$GATEWAY/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || { echo "login falhou"; exit 1; }

echo "hey: $N requisições, concorrência $C, GET /exchange/$PAIR"
# MSYS_NO_PATHCONV: evita o Git Bash do Windows reescrever a URL como caminho
MSYS_NO_PATHCONV=1 docker run --rm --network "$NETWORK" williamyeh/hey \
  -n "$N" -c "$C" -H "Authorization: Bearer $TOKEN" "$GATEWAY_INTERNAL/exchange/$PAIR"
