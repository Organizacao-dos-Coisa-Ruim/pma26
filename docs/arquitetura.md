# Arquitetura

## Visão geral

O cliente só fala com o **gateway**. Nenhum outro serviço é exposto para fora do cluster.

``` mermaid
flowchart LR
    cliente([Cliente]) -->|HTTP :8080| gateway

    subgraph cluster [Kubernetes · namespace pma26]
        gateway[Gateway<br/>Spring Cloud Gateway]
        auth[Auth<br/>JWT]
        account[Account<br/>usuários]
        exchange[Exchange<br/>câmbio]
        order[Order<br/>pedidos]:::pendente
        product[Product<br/>produtos]:::pendente
        redis[(Redis<br/>cache)]
    end

    db[(PostgreSQL<br/>RDS na AWS)]
    awesome[[AwesomeAPI<br/>cotações]]

    gateway -->|/auth/solve valida o token| auth
    gateway --> account & exchange & order & product
    auth -->|Feign| account
    order -.->|Feign| product & exchange
    exchange --> redis
    exchange -->|HTTPS| awesome
    account & order & product --> db

    classDef pendente stroke-dasharray: 5 5
```

As linhas tracejadas são o **Order** e o **Product**, ainda em desenvolvimento.

## Fluxo de uma requisição autenticada

``` mermaid
sequenceDiagram
    participant C as Cliente
    participant G as Gateway
    participant A as Auth
    participant E as Exchange
    participant R as Redis

    C->>G: GET /exchange/USD/BRL<br/>Authorization: Bearer <JWT>
    G->>A: POST /auth/solve {"jwt": "..."}
    A-->>G: {"idAccount": "...", "role": "user"}
    G->>E: GET /exchange/USD/BRL<br/>id-account, role-account (headers)
    E->>R: cotação USD-BRL em cache?
    alt cache hit
        R-->>E: cotação
    else cache miss (1x a cada 5 min por par)
        E->>E: chama a AwesomeAPI e grava no Redis
    end
    E-->>G: {"from": "USD", "to": "BRL", ...}
    G-->>C: 200 OK
```

- O **gateway** é o único que lê o token. Ele pergunta ao Auth quem é o usuário e repassa `id-account` e
  `role-account` em headers. Se o cliente mandar esses headers por conta própria, o gateway os sobrescreve.
- Os serviços **confiam nos headers** e nunca leem o JWT, o que simplifica cada um deles.
- Rotas públicas: `POST /auth/register`, `POST /auth/login` e os health-checks. Todo o resto exige token.
  Algumas rotas exigem `role = admin` ([RBAC](gargalos/rbac.md)).

## Padrão interface + service

Cada domínio tem **dois artefatos Maven**, em dois repositórios:

| Artefato | Conteúdo | Quem usa |
|----------|----------|----------|
| **Interface** (`pma26-auth`, `pma-26-account`, `pma26-exchange`) | `@FeignClient` + DTOs (`record` com `@Builder`) | os outros serviços, para chamar este como se fosse um método Java |
| **Service** (`*-service`) | `Resource` (controller) → `Service` → `Repository` → `Model` (JPA), com `Parser` convertendo Model ↔ DTO | roda em container |

Exemplo: o Auth importa a interface do Account e chama `accountController.login(...)`. O OpenFeign transforma isso em
`POST http://account:8080/accounts/login`. O host `account` é resolvido pelo DNS do Docker Compose (local) ou pelo
Service do Kubernetes.

## Tecnologias

| Camada | Escolha |
|--------|---------|
| Serviços | Java 21, Spring Boot 4.1, Spring Cloud 2025.1 (Gateway, OpenFeign) |
| Banco | PostgreSQL (um schema por serviço, migrações com Flyway); RDS na AWS |
| Cache | Redis |
| Observabilidade | Actuator + Micrometer → Prometheus → Grafana |
| Containers | Docker, Docker Compose (local), Docker Hub (registry) |
| Orquestração | Kubernetes com Kustomize: kind (local) e AWS EKS |
| CI/CD | GitHub Actions |
| Testes de carga | Locust |
