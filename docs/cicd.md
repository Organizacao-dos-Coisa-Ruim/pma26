# CI/CD (GitHub Actions)

Escolhemos **GitHub Actions** em vez de Jenkins (#62): já está integrado aos repositórios, não exige manter um servidor
e é gratuito para repositórios públicos.

## Pipelines

| Repositório | Workflow | Quando | O que faz |
|-------------|----------|--------|-----------|
| `pma-26-account`, `pma26-auth`, `pma26-exchange`, `product`, `order` (interfaces) | `ci.yml` | push/PR | `mvn install` |
| `pma26-account-service`, `pma26-auth-service`, `pma26-exchange-service`, `gateway-service`, `product-service`, `order-service` | `ci.yml` | push/PR | checkout + `mvn install` das interfaces de que dependem, `mvn verify` (testes) |
| | | push na `main` | build da imagem com o `Dockerfile` do repo e **push no Docker Hub** (`<usuario>/<servico>:latest` e `:<sha do commit>`) |
| `pma26` | `smoke-test.yml` | push/PR | builda todos os serviços pelo compose (submodules), sobe tudo e roda [`docker/smoke-test.sh`](https://github.com/Organizacao-dos-Coisa-Ruim/pma26/blob/main/docker/smoke-test.sh) |

```
PR no service ──▶ testes ──(merge)──▶ main ──▶ testes ──▶ imagem no Docker Hub ──▶ (deploy no EKS, #65)
PR no pma26 (novo ponteiro de submodule) ──▶ compose up ──▶ smoke test (39 cenários) ──▶ scan do ZAP
```

### Por que as interfaces são instaladas no CI

Cada service depende das interfaces (`pma:account`, `pma:auth`), que não estão em nenhum repositório Maven público.
O workflow faz checkout delas (`actions/checkout` com `repository:`) e `mvn install` antes de testar o service,
igual ao que o `docker/java-service.Dockerfile` faz no compose.

### Smoke test

O `smoke-test.yml` gera um `docker/.env` com segredos aleatórios **só para o job** (`openssl rand`), sobe o sistema e verifica:
- health-check do auth, account, exchange, product e order;
- register (201) e repetido (409); login errado (401); JWT com `role: user`;
- rota protegida sem token e com token inválido (401); a própria conta (200);
- RBAC: admin recebe `role: admin`; user listar (403), header forjado (403), conta de outro (403); admin listar (200) e apagar (204);
- cotação do Exchange com e sem token e com códigos inválidos;
- produto: sem token (401), inválido (400), criar, consultar, listar, apagar (204) e consultar apagado (404);
- pedido: criar (201) com **total calculado a partir do preço do Product** (3 × 10,12 = 30,36); pedido vazio (400);
  produto inexistente (404), id fora do formato UUID e id que tentaria mudar o caminho da chamada ao Product
  (`health-check`, achado do ZAP), ambos 404; consultar e listar os próprios (200); pedido de outra conta (403).

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
3. Rode de novo o último workflow da `main` de cada service (*Actions → CI → Re-run all jobs*) ou faça um merge qualquer. As imagens aparecem como `<usuario>/account`, `<usuario>/auth`, `<usuario>/exchange`, `<usuario>/gateway`, `<usuario>/product` e `<usuario>/order`.

> O *Run workflow* manual (`workflow_dispatch`) **não** publica a imagem: o passo só roda em evento `push` na `main`.
> O *Re-run* de um workflow que veio de um push funciona, porque mantém o evento original.

## Deploy no EKS (#65)

Job `deploy`, depois do push da imagem, em push na `main`. É o mesmo job nos 6 services (gateway, auth, account,
exchange, product e order); só muda a variável `IMAGE`:

1. configura as credenciais AWS (secrets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`);
2. verifica se o cluster `pma26` existe. Ele só fica de pé durante os testes ([EKS](eks.md)); sem ele, o job pula sem erro;
3. `aws eks update-kubeconfig` + `kubectl set image deployment/<servico> <servico>=<usuario>/<servico>:<sha>` + `rollout status`.

A única diferença é no **order**: o job também troca a imagem do `order-worker`, que roda a mesma imagem e consome a
fila do RabbitMQ (gargalo de mensageria). Sem isso, a API subiria com o código novo e o worker continuaria no antigo.

Usar a **tag do commit** (e não `latest`) faz o Kubernetes perceber a mudança e fazer o rolling update, além de deixar
claro qual versão está rodando (`kubectl get deploy -o wide`).

### Acesso do CI ao cluster

O `up.sh` cria o cluster sem dar acesso a mais ninguém: no EKS, **só a identidade IAM que criou o cluster é admin
dele** por padrão. Se o CI usasse a access key de outro usuário IAM, o `kubectl` responderia `Unauthorized`.

**Decisão:** os secrets `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` do CI são **a mesma access key do usuário IAM
que roda o `up.sh`**. É a opção mais simples: nada a configurar no cluster.

- **Custo da escolha:** o CI tem as mesmas permissões que esse usuário na AWS. Num projeto acadêmico, com o cluster
  ligado só durante os testes, é aceitável.
- **Em produção** faríamos diferente: um usuário (ou role via OIDC do GitHub) só para o CI, com acesso apenas ao
  namespace `pma26`, liberado no cluster com `aws eks create-access-entry`.

Os secrets podem ser da organização (precisa de owner da org) ou de cada repositório de service.

## Evidências (#67)

> TODO: prints da aba Actions (CI verde nos services e smoke test verde no pma26) e das imagens no Docker Hub.
