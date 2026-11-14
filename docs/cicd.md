# CI/CD (GitHub Actions)

Escolhemos **GitHub Actions** em vez de Jenkins (#62): já está integrado aos repositórios, não exige manter um servidor
e é gratuito para repositórios públicos.

## Pipelines

| Repositório | Workflow | Quando | O que faz |
|-------------|----------|--------|-----------|
| `pma-26-account`, `pma26-auth` (interfaces) | `ci.yml` | push/PR | `mvn install` |
| `pma26-account-service`, `pma26-auth-service`, `gateway-service` | `ci.yml` | push/PR | checkout + `mvn install` das interfaces de que dependem, `mvn verify` (testes) |
| | | push na `main` | build da imagem com o `Dockerfile` do repo e **push no Docker Hub** (`<usuario>/<servico>:latest` e `:<sha do commit>`) |
| `pma26` | `smoke-test.yml` | push/PR | builda todos os serviços pelo compose (submodules), sobe tudo e roda [`docker/smoke-test.sh`](../docker/smoke-test.sh) |

```
PR no service ──▶ testes ──(merge)──▶ main ──▶ testes ──▶ imagem no Docker Hub ──▶ (deploy no EKS, #65)
PR no pma26 (novo ponteiro de submodule) ──▶ compose up ──▶ smoke test (15 cenários)
```

### Por que as interfaces são instaladas no CI

Cada service depende das interfaces (`pma:account`, `pma:auth`), que não estão em nenhum repositório Maven público.
O workflow faz checkout delas (`actions/checkout` com `repository:`) e `mvn install` antes de testar o service,
igual ao que o `docker/java-service.Dockerfile` faz no compose.

### Smoke test

O `smoke-test.yml` gera um `docker/.env` com segredos aleatórios **só para o job** (`openssl rand`), sobe o sistema e verifica:
- health-check do auth e do account;
- register (201) e repetido (409); login errado (401); JWT com `role: user`;
- rota protegida sem token e com token inválido (401); a própria conta (200);
- RBAC: admin recebe `role: admin`; user listar (403), header forjado (403), conta de outro (403); admin listar (200) e apagar (204).

Se falhar, mostra os logs dos serviços. Sempre derruba tudo no fim. Para rodar localmente, com o compose de pé:

```bash
set -a; . docker/.env; set +a
bash docker/smoke-test.sh
```

## Configurar o Docker Hub (#66)

Sem estes secrets, o passo de publicar a imagem é **pulado** e o CI continua verde.

1. No [Docker Hub](https://hub.docker.com): *Account settings → Personal access tokens → Generate new token*, com permissão **Read & Write**.
2. No GitHub, na organização: *Settings → Secrets and variables → Actions → New organization secret*:
   - `DOCKERHUB_USERNAME`: o usuário (ou organização) do Docker Hub
   - `DOCKERHUB_TOKEN`: o token do passo 1

   Em *Repository access*, libere para os repositórios de service (ou todos).
3. Rode de novo o último workflow da `main` de cada service (*Actions → CI → Re-run*) ou faça um merge qualquer. As imagens aparecem como `<usuario>/account`, `<usuario>/auth` e `<usuario>/gateway`.

## Próximo passo: deploy no EKS (#65)

Quando o cluster existir: um job depois do push da imagem que configura credenciais AWS (secrets `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`),
roda `aws eks update-kubeconfig` e `kubectl set image deployment/<servico> <servico>=<usuario>/<servico>:<sha>`.

## Evidências (#67)

> TODO: prints da aba Actions (CI verde nos services e smoke test verde no pma26) e das imagens no Docker Hub.
