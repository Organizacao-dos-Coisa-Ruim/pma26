#!/usr/bin/env bash
# Roda o teste de carga (load/locustfile.py) com o Locust em container e, ao mesmo tempo,
# registra o HPA do gateway a cada 5 s. Tudo vai para load/results/<data-hora>/:
#
#   report.html     relatório do Locust (gráficos de RPS, latência, usuários)
#   stats*.csv      números do Locust (por endpoint e ao longo do tempo)
#   hpa.csv         timestamp, CPU média do gateway (% do request), réplicas desejadas e atuais
#   grafico.png     usuários, réplicas, RPS e latência no mesmo eixo de tempo (load/plot.py)
#   events.txt      eventos SuccessfulRescale do HPA
#
# Uso (com o sistema de pé no kind, ver k8s/README.md, e ADMIN_EMAIL/ADMIN_PASSWORD no ambiente):
#   ./load/run.sh                 # 8 minutos, pico de 100 usuários
#   LOAD_SCALE=0.5 ./load/run.sh  # metade do tempo (teste rápido)
#   LOAD_PEAK=200 ./load/run.sh   # pico de 200 usuários
#   UI=1 ./load/run.sh            # interface web em http://localhost:8089 (bom para gravar o vídeo)
#
# No EKS: HOST=http://<endereço do LoadBalancer>:8080 NETWORK=host ./load/run.sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
NETWORK="${NETWORK:-kind}"
HOST="${HOST:-http://pma26-control-plane:30080}"
NAMESPACE="${NAMESPACE:-pma26}"
# o admin cria (e no fim apaga) o catálogo do teste: só admin cria produto (RBAC)
ADMIN_EMAIL="${ADMIN_EMAIL:?defina ADMIN_EMAIL (ex.: set -a; . docker/.env; set +a)}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?defina ADMIN_PASSWORD}"
OUT="$ROOT/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# --- registro do HPA em segundo plano ---------------------------------------------------------
# timestamp Unix, igual ao stats_stats_history.csv do Locust (o load/plot.py junta os dois)
echo "timestamp,cpu_percent,desejadas,atuais" > "$OUT/hpa.csv"
(
  while true; do
    line=$(kubectl -n "$NAMESPACE" get hpa gateway -o \
      jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization},{.status.desiredReplicas},{.status.currentReplicas}' 2>/dev/null || true)
    echo "$(date +%s),$line" >> "$OUT/hpa.csv"
    sleep 5
  done
) &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null || true' EXIT

# --- Locust ----------------------------------------------------------------------------------
if [ "${UI:-0}" = 1 ]; then
  MODE=(-p 8089:8089)
  echo "Locust com interface: abra http://localhost:8089 e clique em Start (a forma da carga já está no script)"
else
  MODE=(--headless)
fi

echo "Carga em $HOST (rede $NETWORK). Resultados em $OUT"
# MSYS_NO_PATHCONV: evita o Git Bash do Windows reescrever os caminhos do container
MSYS_NO_PATHCONV=1 docker run --rm --network "$NETWORK" \
  -e LOAD_SCALE="${LOAD_SCALE:-1}" -e LOAD_PEAK="${LOAD_PEAK:-100}" \
  -e ADMIN_EMAIL="$ADMIN_EMAIL" -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -v "$ROOT:/mnt/locust" -w /mnt/locust \
  locustio/locust:2.32.4 -f locustfile.py --host "$HOST" "${MODE[@]}" \
  --csv "results/$(basename "$OUT")/stats" --csv-full-history \
  --html "results/$(basename "$OUT")/report.html" --only-summary || true

# o HPA continua sendo registrado por mais um tempo para mostrar a redução de réplicas
# (estabilização de 5 min). TAIL=0 pula essa espera.
TAIL="${TAIL:-360}"
if [ "$TAIL" -gt 0 ]; then
  echo "Registrando o HPA por mais ${TAIL}s (redução de réplicas)..."
  sleep "$TAIL"
fi
kill $WATCHER 2>/dev/null || true
kubectl -n "$NAMESPACE" get events --field-selector involvedObject.name=gateway,reason=SuccessfulRescale \
  --sort-by=.lastTimestamp > "$OUT/events.txt" 2>/dev/null || true

# gráfico em container (sem instalar Python/matplotlib na máquina)
MSYS_NO_PATHCONV=1 docker run --rm -v "$OUT:/data" -v "$ROOT/plot.py:/plot.py:ro" python:3.12-slim \
  sh -c "pip install -q --root-user-action=ignore matplotlib==3.9.2 && python /plot.py /data" || echo "(gráfico falhou)"
echo "Pronto: $OUT"
