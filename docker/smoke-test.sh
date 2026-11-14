#!/usr/bin/env bash
# Smoke test do sistema inteiro, pelo gateway: register -> login -> rotas protegidas -> RBAC.
# Usado no CI do pma26 e também localmente, com o compose de pé:
#
#   ADMIN_EMAIL=... ADMIN_PASSWORD=... ./docker/smoke-test.sh
#
# Sai com código != 0 se algum cenário falhar.
set -u

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:?defina ADMIN_EMAIL}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?defina ADMIN_PASSWORD}"
EMAIL="smoke-$(date +%s)@pma26.local"
JSON='Content-Type: application/json'
FAILED=0

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

check() { # check "descrição" esperado obtido
  if [ "$2" = "$3" ]; then
    echo "  ok    $1 ($3)"
  else
    echo "  FALHA $1: esperado $2, veio $3"
    FAILED=1
  fi
}

jwt_field() { # extrai um campo do payload do JWT
  echo "$1" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"
}

login() {
  curl -s -X POST "$GATEWAY/auth/login" -H "$JSON" \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p'
}

echo "Aguardando o gateway em $GATEWAY ..."
for _ in $(seq 1 90); do
  if [ "$(status "$GATEWAY/auth/health-check")" = 200 ] && [ "$(status "$GATEWAY/accounts/health-check")" = 200 ]; then
    break
  fi
  sleep 2
done

echo "Health-check"
check "auth"    200 "$(status "$GATEWAY/auth/health-check")"
check "account" 200 "$(status "$GATEWAY/accounts/health-check")"

echo "Registro e login"
check "register"           201 "$(status -X POST "$GATEWAY/auth/register" -H "$JSON" -d "{\"name\":\"Smoke\",\"email\":\"$EMAIL\",\"password\":\"123456\"}")"
check "register repetido"  409 "$(status -X POST "$GATEWAY/auth/register" -H "$JSON" -d "{\"name\":\"Smoke\",\"email\":\"$EMAIL\",\"password\":\"123456\"}")"
check "login senha errada" 401 "$(status -X POST "$GATEWAY/auth/login" -H "$JSON" -d "{\"email\":\"$EMAIL\",\"password\":\"errada\"}")"
USER_TOKEN="$(login "$EMAIL" 123456)"
USER_ID="$(jwt_field "$USER_TOKEN" sub)"
check "login devolve JWT com role user" user "$(jwt_field "$USER_TOKEN" role)"

echo "Rotas protegidas"
check "sem token"       401 "$(status "$GATEWAY/accounts/$USER_ID")"
check "token inválido"  401 "$(status -H 'Authorization: Bearer invalido' "$GATEWAY/accounts/$USER_ID")"
check "a própria conta" 200 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/accounts/$USER_ID")"

echo "RBAC"
ADMIN_TOKEN="$(login "$ADMIN_EMAIL" "$ADMIN_PASSWORD")"
check "admin recebe role admin"     admin "$(jwt_field "$ADMIN_TOKEN" role)"
check "user lista contas"           403 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/accounts")"
check "user com header forjado"     403 "$(status -H "Authorization: Bearer $USER_TOKEN" -H 'role-account: admin' "$GATEWAY/accounts")"
check "user vê conta de outro"      403 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/accounts/$(jwt_field "$ADMIN_TOKEN" sub)")"
check "admin lista contas"          200 "$(status -H "Authorization: Bearer $ADMIN_TOKEN" "$GATEWAY/accounts")"
check "admin apaga a conta de teste" 204 "$(status -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" "$GATEWAY/accounts/$USER_ID")"

if [ "$FAILED" -ne 0 ]; then
  echo "Smoke test FALHOU"
  exit 1
fi
echo "Smoke test OK"
