#!/usr/bin/env bash
# Smoke test do sistema inteiro, pelo gateway: register -> login -> rotas protegidas -> exchange -> product
# -> RBAC -> pedido (order chamando o product).
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

# faz a requisição e separa corpo e status: define BODY e CODE
request() {
  local out
  out="$(curl -s -w '\n%{http_code}' "$@")"
  CODE="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

json_id() { # campo "id" do BODY (no pedido, "productId" não casa: o padrão exige aspas antes de id)
  echo "$BODY" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

login() {
  curl -s -X POST "$GATEWAY/auth/login" -H "$JSON" \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p'
}

echo "Aguardando o gateway em $GATEWAY ..."
for _ in $(seq 1 90); do
  if [ "$(status "$GATEWAY/auth/health-check")" = 200 ] && [ "$(status "$GATEWAY/accounts/health-check")" = 200 ] \
     && [ "$(status "$GATEWAY/exchange/health-check")" = 200 ] && [ "$(status "$GATEWAY/products/health-check")" = 200 ] \
     && [ "$(status "$GATEWAY/orders/health-check")" = 200 ]; then
    break
  fi
  sleep 2
done

echo "Health-check"
check "auth"    200 "$(status "$GATEWAY/auth/health-check")"
check "account" 200 "$(status "$GATEWAY/accounts/health-check")"
check "exchange" 200 "$(status "$GATEWAY/exchange/health-check")"
check "product" 200 "$(status "$GATEWAY/products/health-check")"
check "order"   200 "$(status "$GATEWAY/orders/health-check")"

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

echo "Exchange"
check "cotação sem token" 401 "$(status "$GATEWAY/exchange/USD/BRL")"
# no CI a AwesomeAPI é um mock (docker/compose.ci.yml); localmente é a API real e precisa de internet
check "cotação com token" 200 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/exchange/USD/BRL")"
check "moedas iguais"     400 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/exchange/BRL/BRL")"
check "código inválido"   400 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/exchange/US/BRL")"

echo "Product"
AUTH="Authorization: Bearer $USER_TOKEN"
check "produtos sem token" 401 "$(status "$GATEWAY/products")"
check "produto inválido"   400 "$(status -X POST "$GATEWAY/products" -H "$AUTH" -H "$JSON" -d '{"name":"Smoke","price":0,"unit":"un"}')"
PRODUCT_ID="$(curl -s -X POST "$GATEWAY/products" -H "$AUTH" -H "$JSON" \
  -d '{"name":"Smoke","price":10.12,"unit":"kg"}' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
check "cria produto (devolve id)" yes "$([ -n "$PRODUCT_ID" ] && echo yes || echo no)"
check "consulta produto"   200 "$(status -H "$AUTH" "$GATEWAY/products/$PRODUCT_ID")"
check "lista produtos"     200 "$(status -H "$AUTH" "$GATEWAY/products")"
check "apaga produto"      204 "$(status -X DELETE -H "$AUTH" "$GATEWAY/products/$PRODUCT_ID")"
check "produto apagado"    404 "$(status -H "$AUTH" "$GATEWAY/products/$PRODUCT_ID")"

echo "RBAC"
ADMIN_TOKEN="$(login "$ADMIN_EMAIL" "$ADMIN_PASSWORD")"
check "admin recebe role admin"     admin "$(jwt_field "$ADMIN_TOKEN" role)"
check "user lista contas"           403 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/accounts")"
check "user com header forjado"     403 "$(status -H "Authorization: Bearer $USER_TOKEN" -H 'role-account: admin' "$GATEWAY/accounts")"
check "user vê conta de outro"      403 "$(status -H "Authorization: Bearer $USER_TOKEN" "$GATEWAY/accounts/$(jwt_field "$ADMIN_TOKEN" sub)")"
check "admin lista contas"          200 "$(status -H "Authorization: Bearer $ADMIN_TOKEN" "$GATEWAY/accounts")"
echo "Order"
# produto próprio para o pedido (o do bloco Product já foi apagado)
request -X POST "$GATEWAY/products" -H "$AUTH" -H "$JSON" -d '{"name":"Tomate","price":10.12,"unit":"kg"}'
PRODUCT_ID="$(json_id)"
check "pedidos sem token"   401 "$(status "$GATEWAY/orders")"
request -X POST "$GATEWAY/orders" -H "$AUTH" -H "$JSON" \
  -d "{\"items\":[{\"productId\":\"$PRODUCT_ID\",\"quantity\":3}]}"
check "cria pedido"         201 "$CODE"
ORDER_ID="$(json_id)"
# 3 x 10.12: o order busca o preço no product (Feign) e calcula o total
check "total do pedido"     30.36 "$(echo "$BODY" | sed -n 's/.*"total":\([0-9.]*\).*/\1/p')"
check "pedido sem itens"    400 "$(status -X POST "$GATEWAY/orders" -H "$AUTH" -H "$JSON" -d '{"items":[]}')"
check "produto inexistente" 404 "$(status -X POST "$GATEWAY/orders" -H "$AUTH" -H "$JSON" -d '{"items":[{"productId":"nao-existe","quantity":1}]}')"
check "consulta o pedido"   200 "$(status -H "$AUTH" "$GATEWAY/orders/$ORDER_ID")"
check "lista meus pedidos"  200 "$(status -H "$AUTH" "$GATEWAY/orders")"
check "pedido de outro"     403 "$(status -H "Authorization: Bearer $ADMIN_TOKEN" "$GATEWAY/orders/$ORDER_ID")"
status -X DELETE -H "$AUTH" "$GATEWAY/products/$PRODUCT_ID" >/dev/null  # limpeza, sem check

check "admin apaga a conta de teste" 204 "$(status -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" "$GATEWAY/accounts/$USER_ID")"

if [ "$FAILED" -ne 0 ]; then
  echo "Smoke test FALHOU"
  exit 1
fi
echo "Smoke test OK"
