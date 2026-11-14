# Onboarding: como começar a contribuir

Guia rápido para quem vai criar um serviço novo (Exchange, Product, Order) ou um gargalo.
Leia antes o [README](../README.md) e a [RUBRICA](../RUBRICA.md).

## 1. Subir o sistema (15 min)

Precisa de **Docker Desktop** e **git**. Java 21 só se for rodar testes fora do Docker.

```bash
git clone --recurse-submodules https://github.com/Organizacao-dos-Coisa-Ruim/pma26.git
cd pma26
cp docker/.env.example docker/.env          # preencha as senhas (qualquer valor local serve)
docker compose -f docker/compose.yml up --build
```

| O quê | Onde |
|-------|------|
| API (só pelo gateway) | http://localhost:8080 |
| Grafana | http://localhost:3000 (`admin` / `GRAFANA_ADMIN_PASSWORD`) |
| Prometheus | http://localhost:9090 |
| Requisições prontas | [`docs/requests.http`](requests.http) (extensão REST Client do VS Code) |

Teste rápido: rode os blocos 1, 2 e 6 do `requests.http` (registrar, logar e ver o 403 de listar contas).

## 2. Como o sistema funciona (o que você precisa saber)

```
cliente ─▶ gateway :8080 ──(valida JWT no auth)──▶ serviço
                │  repassa os headers  id-account  e  role-account
```

- **Só o gateway é público.** Ele já tem rotas para `/products/**`, `/orders/**` e `/exchange/**` apontando para `http://product:8080`, `http://order:8080` e `http://exchange:8080`. Seu serviço só precisa se chamar assim no compose.
- **Toda rota é protegida por padrão** (precisa de token). Para abrir uma rota sem token, adicione-a em `OPEN_ROUTES` no `RouterValidator` do gateway.
- **Quem chamou:** leia os headers `id-account` e `role-account` (`user` ou `admin`). Nunca leia o token no seu serviço. Exemplo pronto: `Requester` e `AccountResource` no account-service.
- **Só admin** (ex.: cadastrar produto): o gateway pode barrar a rota inteira (`ADMIN_ROUTES` no `RouterValidator`), ou o serviço checa `role-account` e devolve 403. Ver [docs/gargalos/rbac.md](gargalos/rbac.md).
- **Chamar outro serviço:** importe a interface dele (ex.: `pma:account`) e use o `@FeignClient`. Exemplo: o auth-service chamando o account (`@EnableFeignClients(clients = AccountController.class)`).

## 3. Criar um serviço novo (padrão interface + service)

Use o **Account** como modelo: [`pma-26-account`](https://github.com/Organizacao-dos-Coisa-Ruim/pma-26-account) (interface) e [`pma26-account-service`](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-account-service) (implementação).

### 3.1 Repositórios

Crie na organização, públicos: `pma26-<dominio>` (interface) e `pma26-<dominio>-service`. O jeito mais rápido é copiar a estrutura do account (`pom.xml`, `mvnw`, `.mvn/`, `.gitignore`, `.gitattributes`) e renomear.

### 3.2 Interface (`pma26-<dominio>`)

- `pom.xml`: `artifactId` = `<dominio>`, **sem** `spring-boot-maven-plugin` (é uma lib).
- Pacote `pma.<dominio>`.
- `<Dominio>Controller`: interface com `@FeignClient(name = "<dominio>", url = "${pma.<dominio>.url:http://<dominio>:8080}")` e as rotas (`@GetMapping`...). Inclua `GET /<recurso>/health-check`.
- DTOs `*In` / `*Out` como `record` com `@Builder`.
- `./mvnw clean install`.

### 3.3 Service (`pma26-<dominio>-service`)

| Arquivo | Copiar de / observação |
|---------|-------------------------|
| `pom.xml` | account-service; troque `artifactId` e a dependência da interface |
| `<Dominio>ServiceApplication` | pacote `pma.<dominio>` |
| `<Dominio>Resource implements <Dominio>Controller` | `@RestController`; só chama o service |
| `<Dominio>Service` | regras; erros com `ResponseStatusException(HttpStatus.X)` |
| `<Dominio>Model` + `<Dominio>Repository` + `<Dominio>Parser` | entidade JPA ≠ DTO |
| `db/migration/V<data>.001__create_table_<x>.sql` | Flyway |
| `application.yaml` | porta 8080, datasource por env, `flyway.schemas: <dominio>`, `hibernate.default_schema: <dominio>`, bloco `management` (métricas) |
| `Dockerfile`, `.dockerignore` | iguais aos do account-service (troque o nome do jar) |
| testes | `*ServiceTest` (Mockito) e `*ResourceIntegrationTest` (`@SpringBootTest` + MockMvc + H2, perfil `test`) |

Cada serviço usa **o mesmo Postgres, num schema próprio** (o Flyway cria o schema).

Sem banco (ex.: Exchange consumindo API externa)? Tire JPA, Flyway e Postgres do pom, como no auth-service.

### 3.4 Plugar no `pma26`

```bash
git submodule add https://github.com/Organizacao-dos-Coisa-Ruim/pma26-<dominio>.git api/<dominio>
git submodule add https://github.com/Organizacao-dos-Coisa-Ruim/pma26-<dominio>-service.git api/<dominio>-service
```

**`docker/compose.yml`**: copie o bloco do `account` e ajuste:

```yaml
  product:
    image: product
    build:
      <<: *java-build
      args:
        INTERFACES: product            # interfaces que o service usa (ex.: "order product account")
        SERVICE: product-service
    environment:
      DATABASE_HOST: db
      DATABASE_PASSWORD: ${DATABASE_PASSWORD:?defina DATABASE_PASSWORD em docker/.env}
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
```

**`docker/observability/prometheus.yml`**: adicione um job, e ele aparece sozinho nos dashboards:

```yaml
  - job_name: product
    metrics_path: /actuator/prometheus
    static_configs:
      - targets: ["product:8080"]
        labels:
          application: product
```

Depois: `docker compose -f docker/compose.yml up --build -d product` e teste pelo gateway (`http://localhost:8080/products/...`).

## 4. Gargalos

Cada integrante precisa de **2 gargalos** com evidência. Já existem: observabilidade e RBAC. Para cada novo:
1. Implemente (ex.: Redis no compose + `@Cacheable` no service).
2. **Meça antes e depois** no Grafana (dashboard "PMA26 - Visão geral": req/s, p95, erros).
3. Documente em `docs/gargalos/<nome>.md` no mesmo formato de [observabilidade.md](gargalos/observabilidade.md): problema, solução, como reproduzir, evidência (prints).

## 5. Fluxo de trabalho

- Branch `feat/<algo>` → PR → merge, em **cada repositório** que mudou. Depois, no `pma26`, atualize o ponteiro do submodule (`git submodule update --remote api/<x>`) e abra o PR dele.
- Commits no padrão `feat:`, `fix:`, `docs:`, `chore:`.
- **Nunca comite segredos.** O `docker/.env` está no `.gitignore`.
- **Uso de IA:** registre em [`docs/ia.md`](ia.md) o que a IA fez e o que você fez. Você precisa conseguir explicar qualquer linha na apresentação.

## 6. Issues por frente (Kanban)

| Frente | Issues |
|--------|--------|
| Exchange | #35 (#36–#40) |
| Product | #24 (#25–#28) |
| Order | #29 (#30–#34) |
| Gargalos | #74: cache Redis #76, mensageria #77, scan de vulnerabilidades #78, load balancing #80, Stripe #81, documentação #82 |
| Custos / PaaS / SLA | #83 (#84–#87) |
| MkDocs | #88 (#89–#92) |
| Apresentação | #93 (#94–#96) |
| AWS / EKS / CI/CD / Load test | #46, #51, #61, #68 |

Prazo: **segunda-feira, 23:59**.
