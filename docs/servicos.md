# Microsserviços

Todos rodam na porta **8080** dentro do container, expõem `GET /<recurso>/health-check` e métricas em
`/actuator/prometheus`. Só o gateway é acessível de fora. Contrato completo das rotas: [API (OpenAPI)](api.md).

## Gateway

[gateway-service](https://github.com/Organizacao-dos-Coisa-Ruim/gateway-service){:target='_blank'} ·
Spring Cloud Gateway (WebFlux)

- Roteia por prefixo: `/auth/**`, `/accounts/**`, `/exchange/**`, `/products/**`, `/orders/**`.
- `AuthorizationFilter`: nas rotas protegidas, valida o JWT chamando `POST /auth/solve` e repassa
  `id-account` / `role-account` em headers. Também barra rotas só de admin ([RBAC](gargalos/rbac.md)).
- `SecurityHeadersFilter`: adiciona headers de segurança em toda resposta ([scan de vulnerabilidades](gargalos/scan-vulnerabilidades.md)).
- É o deployment escalado pelo **HPA** ([load test](load-test.md)).

## Auth

[pma26-auth](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-auth){:target='_blank'} ·
[pma26-auth-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-auth-service){:target='_blank'}

| Rota | O que faz |
|------|-----------|
| `POST /auth/register` | cria a conta (chama o Account via Feign) |
| `POST /auth/login` | confere a senha no Account e devolve um **JWT** com `sub` = id da conta e `role` |
| `POST /auth/solve` | valida o JWT e devolve `idAccount` e `role` (usado só pelo gateway) |

O Auth não tem banco: os dados do usuário ficam no Account.

## Account

[pma-26-account](https://github.com/Organizacao-dos-Coisa-Ruim/pma-26-account){:target='_blank'} ·
[pma26-account-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-account-service){:target='_blank'}

CRUD de usuários (nome, email, senha com **BCrypt**), schema `account` no PostgreSQL (Flyway).
Um usuário só vê a própria conta; listar e apagar contas é só para admin. O admin inicial é criado a partir de
variáveis de ambiente (`AdminBootstrap`).

## Exchange

[pma26-exchange](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-exchange){:target='_blank'} ·
[pma26-exchange-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-exchange-service){:target='_blank'}

`GET /exchange/{de}/{para}` devolve a cotação entre duas moedas (ex.: `USD/BRL`), consultando a
[AwesomeAPI](https://docs.awesomeapi.com.br/){:target='_blank'}. A cotação fica **em cache no Redis por 5 minutos**
([gargalo](gargalos/cache-redis.md)). Será usado pelo Order para mostrar o total do pedido em outra moeda.

## Product

[product](https://github.com/Organizacao-dos-Coisa-Ruim/product){:target='_blank'} ·
[product-service](https://github.com/Organizacao-dos-Coisa-Ruim/product-service){:target='_blank'}

Catálogo de produtos no formato do enunciado (`id`, `name`, `price`, `unit`), schema `products` no PostgreSQL (Flyway).
Rotas: `POST /products`, `GET /products`, `GET /products/{id}` e `DELETE /products/{id}`. Os campos são validados
com Bean Validation (`@Valid` na interface), com limites iguais aos das colunas, então dado inválido vira `400` e não
`500`. O Order consulta `GET /products/{id}` via Feign para montar o pedido.

## Order

[order](https://github.com/Organizacao-dos-Coisa-Ruim/order){:target='_blank'} ·
[order-service](https://github.com/Organizacao-dos-Coisa-Ruim/order-service){:target='_blank'}

Pedidos, schema `orders` no PostgreSQL (Flyway).

| Rota | O que faz |
|------|-----------|
| `POST /orders` | cria um pedido: `{"items": [{"productId": "...", "quantity": 3}]}` |
| `GET /orders`, `GET /orders/{id}` | pedidos **da conta logada** (pedido de outra conta → 403) |

Ao criar um pedido, o Order **não confia no preço enviado pelo cliente**: para cada item ele chama o Product via
Feign (`GET http://product:8080/products/{id}`), guarda nome e preço unitário daquele momento e calcula subtotal e
total. Produto inexistente ou id recusado pelo Product → 404; Product fora do ar → 503. O dono do pedido vem do
header `id-account`, que o gateway preenche a partir do JWT.

Antes de chamar o Product, o Order confere se o `productId` tem o formato **UUID** (o formato dos ids que o Product
gera). Como o id vira parte do caminho da chamada interna, sem essa checagem um valor como `health-check` ou `..%2f`
mudava a requisição ao Product e o pedido respondia 502/503 (achado do scan do ZAP). Id fora do formato → 404, sem
chamar o Product.
