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
        order[Order<br/>pedidos]
        product[Product<br/>produtos]
        redis[(Redis<br/>cache)]
    end

    db[(PostgreSQL<br/>RDS na AWS)]
    awesome[[AwesomeAPI<br/>cotações]]

    gateway -->|/auth/solve valida o token| auth
    gateway --> account & exchange & order & product
    auth -->|Feign| account
    order -->|Feign| product
    order -.->|Feign, #39| exchange
    exchange --> redis
    exchange -->|HTTPS| awesome
    account & order & product --> db
```

A linha tracejada (Order → Exchange, total do pedido em outra moeda) ainda não foi implementada (#39).
Localmente, no Docker Compose, um **Nginx** distribui as requisições entre 3 réplicas do gateway
([load balancing](gargalos/load-balancing.md)). No EKS, esse papel é do load balancer da AWS junto com o HPA.

## Infraestrutura na AWS

Criada pelo `k8s/overlays/eks/up.sh` e destruída pelo `down.sh` ([EKS e AWS](eks.md)), na região `us-east-1`.

``` mermaid
flowchart TB
    cliente([Cliente]) -->|HTTP| clb
    gha[GitHub Actions] -->|push da imagem| hub[(Docker Hub)]
    gha -->|kubectl set image| cp

    subgraph aws [AWS · us-east-1]
        cp["EKS control plane<br/>(gerenciado pela AWS)"]

        subgraph vpc ["VPC pma26-vpc (CloudFormation)"]
            igw[Internet Gateway]
            clb["Classic Load Balancer<br/>Service gateway type LoadBalancer"]

            subgraph za [Zona de disponibilidade A]
                pubA["Subnet pública A<br/>NAT Gateway"]
                privA["Subnet privada A<br/>nó t3.medium"]
            end

            subgraph zb [Zona de disponibilidade B]
                pubB["Subnet pública B<br/>NAT Gateway"]
                privB["Subnet privada B<br/>nó t3.medium"]
            end

            rds[("RDS PostgreSQL db.t3.micro<br/>Single-AZ, sem IP público")]
        end
    end

    clb --- igw
    clb -->|NodePort| privA & privB
    privA -->|saída para a internet| pubA
    privB -->|saída para a internet| pubB
    pubA & pubB --> igw
    igw -->|imagens| hub
    igw -->|cotações| awesome[[AwesomeAPI]]
    privA & privB -->|5432| rds
    cp -.->|agenda os pods| privA & privB
```

| Peça | Onde fica | Por quê |
|------|-----------|---------|
| **VPC** | template oficial `amazon-eks-vpc-private-subnets.yaml` (CloudFormation) | 2 subnets públicas e 2 privadas, em 2 zonas de disponibilidade, como pede a rubrica |
| **Load balancer** | subnets públicas | único ponto com IP público que recebe tráfego; criado pelo Kubernetes a partir do `Service` do gateway (`type: LoadBalancer`) e repassa para os nós pela porta do NodePort |
| **Nós (node group)** | **só nas subnets privadas**, um por zona | os pods (gateway, auth, account, exchange, product, order, redis) não ficam expostos na internet; se uma zona cair, a outra continua |
| **NAT Gateways** | um em cada subnet pública | dão aos nós privados **saída** para a internet (baixar as imagens do Docker Hub e chamar a AwesomeAPI) sem permitir **entrada** |
| **RDS** | subnets privadas, sem acesso público | o security group só aceita a porta 5432 vinda do cluster; cada serviço usa o seu schema |
| **Control plane** | gerenciado pela AWS, fora da VPC do projeto | a AWS cuida do API server e do etcd; o CI acessa pela API do cluster para o deploy contínuo |

Prometheus e Grafana não sobem na AWS: ficam no Docker Compose local, por custo ([custos](custos.md#onde-usamos-paas)).

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
