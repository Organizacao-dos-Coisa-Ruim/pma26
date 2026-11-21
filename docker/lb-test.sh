#!/usr/bin/env bash
# Evidência do load balancing (gargalo #80), com o compose de pé:
#
#   ./docker/lb-test.sh
#
# 1. Distribuição: manda N requisições pelo load balancer (Nginx) e conta, no log dele, quantas
#    cada réplica do gateway atendeu.
# 2. Queda de uma réplica: manda requisições sem parar por DURACAO segundos, mata uma réplica aos
#    5 s (docker kill, como um crash) e conta quantas requisições o cliente viu falhar. No fim, sobe
#    a réplica de novo.
#
# Variáveis: GATEWAY (padrão http://localhost:8080), COMPOSE_PROJECT_NAME (padrão pma26),
# N (requisições da fase 1, padrão 300) e DURACAO (segundos da fase 2, padrão 20).
# Para a queda aparecer bem no Grafana (média do último minuto), use DURACAO=120.
set -u

GATEWAY="${GATEWAY:-http://localhost:8080}"
PROJECT="${COMPOSE_PROJECT_NAME:-pma26}"
N="${N:-300}"
DURACAO="${DURACAO:-20}"
RUN="lb$(date +%s)"   # marcador nas URLs, para achar só as requisições deste teste no log do Nginx

containers() { # containers rodando de um serviço do compose
  docker ps --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | sort
}
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

LB="$(containers lb | head -1)"
REPLICAS="$(containers gateway)"
[ -n "$LB" ] && [ -n "$REPLICAS" ] || { echo "compose '$PROJECT' sem lb ou gateway rodando"; exit 1; }

# IP de cada réplica, guardado antes da queda (a réplica derrubada perde o IP)
declare -A IP
for r in $REPLICAS; do IP[$r]="$(ip_of "$r")"; done

distribution() { # requisições com o marcador $1 no log do Nginx, por réplica
  sleep 1  # dá tempo de a última linha chegar ao log
  local logs
  logs="$(docker logs "$LB" 2>/dev/null | grep "$1")"
  for r in $REPLICAS; do
    printf '  %-26s %4s requisições\n' "$r" "$(echo "$logs" | grep -c "upstream=${IP[$r]}:8080")"
  done
  # quando uma réplica falha no meio, o Nginx registra as duas tentativas: "upstream=IP1:8080, IP2:8080"
  printf '  %-26s %4s\n' "reenviadas a outra réplica" "$(echo "$logs" | grep -c 'upstream=[^ ]*, ')"
}

echo "Réplicas do gateway: $(echo $REPLICAS | wc -w) ($(echo $REPLICAS))"
echo
echo "1) Distribuição de $N requisições (round-robin)"
for _ in $(seq 1 "$N"); do curl -s -o /dev/null "$GATEWAY/health-check?$RUN-dist"; done
distribution "$RUN-dist"

echo
VICTIM="$(echo "$REPLICAS" | tail -1)"   # a última réplica (com GATEWAY_REPLICAS=1, a única)
echo "2) Queda de uma réplica: requisições por $DURACAO s, com $VICTIM morta aos 5 s"
total=0; depois=0; erros=0; pior=0; killed=0; start=$SECONDS
while [ $((SECONDS - start)) -lt "$DURACAO" ]; do
  if [ "$killed" = 0 ] && [ $((SECONDS - start)) -ge 5 ]; then
    docker kill "$VICTIM" > /dev/null && killed=1 && echo "  $(date +%T) $VICTIM morta"
  fi
  out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 "$GATEWAY/health-check?$RUN-queda")"
  total=$((total + 1))
  [ "$killed" = 1 ] && depois=$((depois + 1))
  [ "${out%% *}" = 200 ] || erros=$((erros + 1))
  ms="$(awk -v t="${out#* }" 'BEGIN { printf "%d", t * 1000 }')"
  [ "$ms" -gt "$pior" ] && pior=$ms
done
echo "  requisições: $total ($depois depois da queda) | erros vistos pelo cliente: $erros | pior latência: ${pior} ms"
distribution "$RUN-queda"

echo
echo "Subindo $VICTIM de novo..."
docker start "$VICTIM" > /dev/null && echo "  ok (o Nginx volta a mandar tráfego para ela em até ~10 s)"
echo
echo "No Grafana (http://localhost:3000), painel 'Gateway: requisições por réplica (load balancing)'."
[ "$erros" -eq 0 ]
