# CLAUDE.md — pma26

Repositório principal do projeto de **Plataformas, Microsserviços e APIs (Insper, 2026.2)**: um e-commerce em microsserviços Spring Boot, rodando na AWS (EKS).

## ⚠️ Antes de qualquer tarefa: leia `RUBRICA.md`

**Sempre leia [RUBRICA.md](RUBRICA.md) antes de planejar ou implementar algo.** Ela define o que vale nota, e toda decisão deve ser tomada com ela em mente:

- Diga a qual item da rubrica a tarefa contribui (ex.: "Bottlenecks — cache com Redis").
- Se a tarefa não contribui para nenhum item, avise antes de gastar esforço nela.
- Lembre que **80% da nota não é código de serviço**: gargalos (20%), load test (15%), EKS (10%), CI/CD (10%), custos (10%), MkDocs (10%), AWS (5%). Não fique polindo CRUD.
- Ao terminar algo que corresponde a um item do checklist da rubrica, sugira marcá-lo.

## Regras de uso de IA (exigidas pelo curso)

- No código, a IA é **parcialmente** permitida: boilerplate, sugestões, correção de erros. **Não implemente uma feature inteira sem o usuário pedir explicitamente.** Na dúvida, proponha e espere aprovação.
- **Registre o uso de IA** em `docs/ia.md` (crie se não existir): data, serviço/arquivo, o que a IA fez e o que o integrante fez. A documentação final precisa declarar isso.
- Explique o que foi feito de forma que qualquer integrante consiga **defender o código na apresentação**. Prefira soluções simples e explicáveis a soluções "espertas".

## Arquitetura

```
              Internet
                 │
            [ Gateway ]  ← único ponto de entrada, valida o token (JWT) com o Auth
     ┌──────┬────┴────┬──────────┬─────────┐
  [Auth] [Account] [Exchange] [Product] [Order]
     │       │                    │         │
     └───────┴──── PostgreSQL (RDS em produção) ┘
```

- **Gateway**: Spring Cloud Gateway. Roteia por prefixo (`/auth/**`, `/accounts/**`, `/exchange/**`, `/products/**`, `/orders/**`) e checa o token nas rotas protegidas.
  Contrato com o Auth: `POST /auth/solve {"jwt": "..."}` → `{"idAccount": "...", "role": "..."}`. O gateway repassa `id-account` e `role-account` em headers; os serviços confiam nesses headers e nunca leem o token.
- **Auth**: login e emissão/validação de JWT. Consulta o Account via Feign.
- **Account**: CRUD de usuários.
- **Exchange**: câmbio entre moedas.
- **Product / Order**: domínio do e-commerce.
- Os serviços se comunicam por **HTTP via OpenFeign**, usando o nome do serviço como host (`http://account:8080`): DNS do Docker Compose localmente e Service do Kubernetes no EKS.
- Os serviços nunca são expostos diretamente: só o gateway tem acesso externo.

### Padrão interface + service (padrão do curso)

Cada domínio tem **dois repositórios / dois artefatos Maven**:

| Repositório | Papel | Exemplo |
|-------------|-------|---------|
| `<dominio>` | **Interface**: `@FeignClient` + DTOs (`*In` / `*Out` como `record`). É uma lib que os outros serviços importam para chamar este. | `api/account` |
| `<dominio>-service` | **Implementação**: implementa a interface, com `Resource` (controller), `Service`, `Repository`, `Model` e o banco. É o que roda em container. | `api/account-service` |

- A interface **precisa ser instalada antes** do service (`mvn clean install` na interface).
- DTOs: `record` com `@Builder` (Lombok). Entidade JPA (`*Model`) ≠ DTO; converta numa classe `*Parser`.
- Todo serviço expõe `GET /<recurso>/health-check`.

## Estrutura do repositório

```
pma26/
├── CLAUDE.md
├── RUBRICA.md
├── api/                 ← microsserviços, cada um é um git submodule
│   ├── account/         → interface Account (Feign + DTOs)
│   ├── account-service/ → implementação do Account
│   ├── auth/            → interface Auth (Feign + DTOs)
│   ├── auth-service/    → implementação do Auth (registro, login, JWT)
│   └── gateway-service/ → API Gateway (Spring Cloud Gateway, WebFlux)
├── docker/
│   ├── compose.yml              ← sobe o sistema inteiro localmente
│   ├── java-service.Dockerfile  ← build genérico (interfaces + service) usado pelo compose
│   ├── .env.example             ← variáveis; copiar para docker/.env (fora do git)
│   └── observability/           ← prometheus.yml + provisioning e dashboards do Grafana
├── k8s/                 ← (a criar) manifests do Kubernetes/EKS: deployment, service, hpa
└── docs/                ← MkDocs (a criar) + ia.md (registro de uso de IA)
```

## Stack

- Java **21**, Spring Boot **4.1.x**, Spring Cloud **2025.1.x** (OpenFeign, Gateway), Lombok, Maven Wrapper (`./mvnw`).
- Banco: PostgreSQL (container local, RDS na AWS). Migrações com Flyway.
- Containers: Docker, Docker Compose (local), Docker Hub (registry).
- Nuvem: AWS EKS, RDS, VPC via CloudFormation.
- CI/CD: Jenkins ou GitHub Actions (build → push Docker Hub → deploy EKS).
- Observabilidade: Spring Actuator + Micrometer + Prometheus + Grafana.

Mantenha as versões alinhadas entre os serviços (hoje todos no Boot 4.1.1).

## Convenções

- **Pacotes:** `pma.<dominio>` (ex.: `pma.account`, `pma.auth`).
- **Porta:** todo serviço roda na **8080** dentro do container; só o gateway é publicado para fora.
- **Configuração:** `application.yaml`, com valores sensíveis vindos de **variáveis de ambiente** (`${DATABASE_HOST}`, `${JWT_SECRET}`...). **Nunca comite segredos**, credenciais AWS ou senhas.
- **Dockerfile** na raiz de cada `*-service` (multi-stage ou a partir do jar).
- **Nomes de imagem/deployment/service** iguais ao nome do serviço (`gateway`, `auth`, `account`...), porque o HPA e o load test usam esses nomes.
- **Commits:** Conventional Commits em português ou inglês (`feat:`, `fix:`, `docs:`, `chore:`).
- **Senhas:** sempre com hash (BCrypt / SHA-256 + salt), nunca em texto puro.

## Trabalhando com submodules

```bash
# clonar tudo
git clone --recurse-submodules https://github.com/Organizacao-dos-Coisa-Ruim/pma26.git

# atualizar os submodules para o último commit de cada repo
git submodule update --remote --merge

# adicionar um novo serviço
git submodule add https://github.com/Organizacao-dos-Coisa-Ruim/<repo>.git api/<nome>
```

- Alterações em um serviço são **commitadas e pushadas no repositório do serviço**. Depois, no `pma26`, comite o novo ponteiro do submodule.
- Não edite o código de um serviço "por dentro" do `pma26` sem commitar no repositório dele: a mudança se perde.

## Rodando localmente

```bash
cp docker/.env.example docker/.env      # preencher DATABASE_PASSWORD e JWT_SECRET
docker compose -f docker/compose.yml up --build
```

- Só precisa de Docker: o `docker/java-service.Dockerfile` (contexto `api/`) instala as interfaces e empacota o service dentro do container. Ao criar um serviço novo, adicione-o no `compose.yml` com `INTERFACES` (interfaces de que ele depende) e `SERVICE`.
- Só o gateway publica porta (`localhost:8080`). Postgres único (`store`), cada serviço no seu schema (Flyway).
- `docker/.env` tem segredos e está no `.gitignore`; nunca comitar.
- Fluxo de teste manual: `docs/requests.http` (VS Code REST Client). Detalhes no `README.md`.

## Como o Claude deve trabalhar aqui

1. **Leia `RUBRICA.md`** e diga qual item a tarefa atende.
2. **Não escreva código sem o usuário pedir.** Para pedidos de análise ou planejamento, entregue o plano e espere.
3. Antes de mudar um serviço, leia o código existente dele e siga o padrão interface + service.
4. Mudanças pequenas e focadas, num serviço por vez; diga em qual repositório (submodule) a mudança precisa ser commitada.
5. Não faça commit, push, deploy na AWS nem crie recursos pagos sem confirmação explícita. **EKS/RDS custam dinheiro**: lembre de derrubar os recursos ao final dos testes.
6. Ao concluir, atualize `docs/ia.md` e, se for o caso, o checklist da `RUBRICA.md`.
7. Responda em **português**.
