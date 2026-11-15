#!/usr/bin/env bash
# Scan de vulnerabilidades (OWASP ZAP API Scan) contra o gateway, com o compose de pé.
# Usado no CI do pma26 (depois do smoke test) e localmente:
#
#   ./docker/zap-scan.sh [pasta-do-relatório]      # padrão: zap-report/
#
# O ZAP lê as rotas de docs/openapi.yaml, ataca cada uma (injeção, headers, erros...) e gera
# relatório HTML e JSON. Para testar também as rotas protegidas, cria um usuário comum e manda
# o JWT dele em todas as requisições.
#
# Sai com código != 0 se houver qualquer alerta de nível WARN ou FAIL (rodar sem -I é proposital:
# todo alerta novo quebra o CI). Ajustes de regras, se precisar, vão em .zap/rules.tsv.
set -eu

REPORT_DIR="${1:-zap-report}"
GATEWAY="${GATEWAY:-http://localhost:8080}"
NETWORK="${NETWORK:-pma26_default}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON='Content-Type: application/json'
EMAIL="zap-$(date +%s)@pma26.local"

curl -s -o /dev/null -X POST "$GATEWAY/auth/register" -H "$JSON" \
  -d "{\"name\":\"ZAP\",\"email\":\"$EMAIL\",\"password\":\"zap-123456\"}"
TOKEN="$(curl -s -X POST "$GATEWAY/auth/login" -H "$JSON" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"zap-123456\"}" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || { echo "login do usuário do ZAP falhou"; exit 1; }

mkdir -p "$REPORT_DIR"
cp "$ROOT/docs/openapi.yaml" "$REPORT_DIR/"
[ -f "$ROOT/.zap/rules.tsv" ] && cp "$ROOT/.zap/rules.tsv" "$REPORT_DIR/" && RULES="-c rules.tsv" || RULES=""
# o container do ZAP roda com outro usuário e precisa escrever o relatório na pasta montada
chmod 777 "$REPORT_DIR"

# MSYS_NO_PATHCONV: evita o Git Bash do Windows reescrever os caminhos do container
# -O: as requisições vão para o gateway pelo nome do serviço na rede do compose
MSYS_NO_PATHCONV=1 docker run --rm --network "$NETWORK" \
  -v "$(cd "$REPORT_DIR" && pwd -W 2>/dev/null || pwd)":/zap/wrk:rw \
  -e ZAP_AUTH_HEADER=Authorization \
  -e ZAP_AUTH_HEADER_VALUE="Bearer $TOKEN" \
  -e ZAP_AUTH_HEADER_SITE=gateway \
  zaproxy/zap-stable zap-api-scan.py \
  -t /zap/wrk/openapi.yaml -f openapi -O http://gateway:8080 \
  -r zap-report.html -J zap-report.json $RULES
