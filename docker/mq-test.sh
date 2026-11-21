#!/usr/bin/env bash
# Evidência da mensageria (gargalo #77), com o compose de pé:
#
#   ADMIN_EMAIL=... ADMIN_PASSWORD=... RABBITMQ_PASSWORD=... ./docker/mq-test.sh
#
# 1. Latência: cria pedidos e mede o tempo do POST /orders. Com a fila, o cliente não espera o envio
#    da confirmação (~2 s); o pedido sai PENDENTE e o order-worker confirma logo depois.
#    Para o "antes" (confirmação dentro da requisição):
#      ORDER_CONFIRMATION_ASYNC=false docker compose -f docker/compose.yml up -d order
# 2. Worker fora do ar: para o order-worker, cria N pedidos (todos aceitos, PENDENTE), mostra as
#    mensagens esperando na fila, religa o worker e mede quanto tempo ele leva para esvaziar a fila.
#
# Variáveis: GATEWAY (padrão http://localhost:8080), COMPOSE_PROJECT_NAME (padrão pma26), N (padrão 10),
# RABBITMQ_UI (padrão http://localhost:15672).
set -u

GATEWAY="${GATEWAY:-http://localhost:8080}"
PROJECT="${COMPOSE_PROJECT_NAME:-pma26}"
N="${N:-10}"
RABBITMQ_UI="${RABBITMQ_UI:-http://localhost:15672}"
ADMIN_EMAIL="${ADMIN_EMAIL:?defina ADMIN_EMAIL}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?defina ADMIN_PASSWORD}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:?defina RABBITMQ_PASSWORD}"
JSON='Content-Type: application/json'

container() { # container rodando de um serviço do compose (inclusive parado, para o docker start)
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | head -1
}
field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }
queue_ready() { # mensagens esperando na fila, pela API do painel do RabbitMQ (atualizada a cada ~5 s)
  curl -s -u "pma26:$RABBITMQ_PASSWORD" "$RABBITMQ_UI/api/queues/%2F/order-created" | sed -n 's/.*"messages_ready":\([0-9]*\).*/\1/p'
}
count_status() { # pedidos da conta com o status $1
  curl -s -H "$AUTH" "$GATEWAY/orders" | grep -o "\"status\":\"$1\"" | wc -l
}

TOKEN="$(curl -s -X POST "$GATEWAY/auth/login" -H "$JSON" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | field jwt)"
[ -n "$TOKEN" ] || { echo "login do admin falhou"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"
PRODUCT_ID="$(curl -s -X POST "$GATEWAY/products" -H "$AUTH" -H "$JSON" \
  -d '{"name":"Teste fila","price":10.00,"unit":"un"}' | field id)"
ORDER_BODY="{\"items\":[{\"productId\":\"$PRODUCT_ID\",\"quantity\":1}]}"
WORKER="$(container order-worker)"

echo "1) Latência do POST /orders ($N pedidos)"
total_ms=0; pior=0
for _ in $(seq 1 "$N"); do
  out="$(curl -s -w ' %{time_total}' -X POST "$GATEWAY/orders" -H "$AUTH" -H "$JSON" -d "$ORDER_BODY")"
  ms="$(awk -v t="${out##* }" 'BEGIN { printf "%d", t * 1000 }')"
  total_ms=$((total_ms + ms)); [ "$ms" -gt "$pior" ] && pior=$ms
  status="$(echo "${out% *}" | field status)"
done
echo "  média: $((total_ms / N)) ms | pior: ${pior} ms | status na resposta: $status"
inicio=$SECONDS
until [ "$(count_status PENDENTE)" -eq 0 ] || [ $((SECONDS - inicio)) -ge 120 ]; do sleep 1; done
echo "  todos CONFIRMADO $((SECONDS - inicio)) s depois do último POST (o worker envia ~1 confirmação a cada 2 s)"

echo
echo "2) Worker fora do ar"
docker stop "$WORKER" > /dev/null && echo "  $(date +%T) $WORKER parado"
aceitos=0
for _ in $(seq 1 "$N"); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/orders" -H "$AUTH" -H "$JSON" -d "$ORDER_BODY")"
  [ "$code" = 201 ] && aceitos=$((aceitos + 1))
done
sleep 6   # a contagem do painel do RabbitMQ é atualizada a cada ~5 s
echo "  pedidos aceitos com o worker parado: $aceitos de $N | PENDENTE: $(count_status PENDENTE) | mensagens na fila: $(queue_ready)"
echo "  $(date +%T) religando $WORKER (a JVM leva alguns segundos para subir)..."
docker start "$WORKER" > /dev/null
inicio=$SECONDS
until [ "$(count_status PENDENTE)" -eq 0 ] || [ $((SECONDS - inicio)) -ge 600 ]; do sleep 2; done
sleep 6
echo "  $(date +%T) fila esvaziada $((SECONDS - inicio)) s depois de religar | PENDENTE: $(count_status PENDENTE) | mensagens na fila: $(queue_ready)"

curl -s -o /dev/null -X DELETE -H "$AUTH" "$GATEWAY/products/$PRODUCT_ID"
echo
echo "No painel do RabbitMQ ($RABBITMQ_UI, usuário pma26): Queues and Streams → order-created."
