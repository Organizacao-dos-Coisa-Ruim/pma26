# pma26

E-commerce em microsserviços Spring Boot. Projeto de **Plataformas, Microsserviços e APIs** (Insper, 2026.2).

```
              Internet
                 │
            [ Gateway ]  :8080, único ponto de entrada; valida o JWT com o Auth
          ┌──────┴──────┐
       [Auth] ──Feign──▶ [Account] ──▶ PostgreSQL
```

| Serviço | Repositório | Pasta |
|---------|-------------|-------|
| Gateway | [gateway-service](https://github.com/Organizacao-dos-Coisa-Ruim/gateway-service) | `api/gateway-service` |
| Auth | [pma26-auth](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-auth) (interface) · [pma26-auth-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-auth-service) | `api/auth`, `api/auth-service` |
| Account | [pma-26-account](https://github.com/Organizacao-dos-Coisa-Ruim/pma-26-account) (interface) · [pma26-account-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-account-service) | `api/account`, `api/account-service` |

## Rodando localmente

Só precisa de **Docker** (Docker Desktop no Windows/Mac) e **git**. Java e Maven não são necessários:
o build acontece dentro dos containers.

```bash
# 1. clonar com os submodules
git clone --recurse-submodules https://github.com/Organizacao-dos-Coisa-Ruim/pma26.git
cd pma26

# 2. variáveis de ambiente: copie e preencha DATABASE_PASSWORD e JWT_SECRET (mín. 32 caracteres)
cp docker/.env.example docker/.env

# 3. buildar e subir tudo
docker compose -f docker/compose.yml up --build
```

O primeiro build demora alguns minutos (baixa as dependências do Maven); os próximos usam cache.
O sistema fica em **http://localhost:8080**.

| Comando | Para quê |
|---------|----------|
| `docker compose -f docker/compose.yml up --build -d` | sobe em segundo plano |
| `docker compose -f docker/compose.yml logs -f auth` | logs de um serviço |
| `docker compose -f docker/compose.yml ps` | status dos containers |
| `docker compose -f docker/compose.yml down` | derruba (os dados do Postgres ficam no volume) |
| `docker compose -f docker/compose.yml down -v` | derruba e **apaga o banco** |
| `git submodule update --remote --merge` | puxa a última versão de cada serviço |

### Como o build funciona

Cada service depende das **interfaces** (libs Feign) de outros serviços, que precisam ser instaladas
no Maven antes. O [`docker/java-service.Dockerfile`](docker/java-service.Dockerfile) recebe a pasta `api/` inteira como contexto e,
dentro do container, faz `mvn install` nas interfaces e depois `mvn package` no service:

| Serviço | Interfaces instaladas antes |
|---------|-----------------------------|
| `account` | `account` |
| `auth` | `auth`, `account` |
| `gateway` | – |

Os `Dockerfile` dentro de cada repositório de service continuam valendo para o CI (a partir do jar).

## Testando o fluxo

Abra [`docs/requests.http`](docs/requests.http) no VS Code com a extensão **REST Client** e execute os blocos em ordem
(register → login → rota protegida com o token). Ou com `curl`:

```bash
curl -X POST localhost:8080/auth/register -H 'Content-Type: application/json' \
  -d '{"name":"Ana","email":"ana@insper.edu.br","password":"123456"}'          # 201

TOKEN=$(curl -s -X POST localhost:8080/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"ana@insper.edu.br","password":"123456"}' | sed 's/.*"jwt":"\([^"]*\)".*/\1/')

curl -i localhost:8080/accounts                                    # 401 (sem token)
curl -i localhost:8080/accounts -H "Authorization: Bearer $TOKEN"  # 200
```

## Desenvolvimento sem Docker (opcional)

Para rodar testes ou abrir na IDE, com Java 21: instale as interfaces antes dos services.

```bash
(cd api/account && ./mvnw clean install)
(cd api/auth && ./mvnw clean install)
(cd api/account-service && ./mvnw clean package)
(cd api/auth-service && ./mvnw clean package)
(cd api/gateway-service && ./mvnw clean package)
```

## Documentação

- [RUBRICA.md](RUBRICA.md): critérios de avaliação e checklist
- [docs/ia.md](docs/ia.md): registro de uso de IA
