# Gargalo: RBAC (controle de acesso por papel)

## Problema

Antes, ter um token válido bastava para tudo. Qualquer usuário logado conseguia:
- listar **todas** as contas (`GET /accounts`);
- ver e **apagar** a conta de qualquer pessoa (`GET`/`DELETE /accounts/{id}`);
- chamar `POST /accounts/login` pelo gateway e testar senhas de outros emails (um "oráculo" de senha).

Além disso, o papel no JWT era sempre `user`: não existia admin.

## Solução

Dois papéis, `user` e `admin`, com a checagem em **duas camadas**:

```
cliente ─▶ gateway ──(1) rota só de admin? role != admin → 403
                   └─ repassa id-account / role-account ─▶ account ──(2) é a própria conta ou admin? senão 403
```

| Peça | O que faz |
|------|-----------|
| **Account** | Coluna `tx_role` (migration Flyway; contas antigas viram `user`). Conta criada pela API é sempre `user`. O primeiro `admin` é criado na subida pelo `AdminBootstrap`, a partir de `ADMIN_EMAIL`/`ADMIN_PASSWORD` (no código, porque a senha passa pelo BCrypt) |
| **Auth** | Coloca no JWT o `role` real que vem do Account |
| **Gateway** (camada 1) | Rotas só de admin devolvem 403 sem chegar ao serviço |
| **Account** (camada 2) | Com os headers do gateway, confere a regra de novo e a regra de "dono" (`GET /accounts/{id}`), que o gateway não tem como saber |

### Regras

| Rota | `user` | `admin` |
|------|--------|---------|
| `POST /auth/register`, `POST /auth/login` | aberta | aberta |
| `GET /accounts/{id}` | só a própria | qualquer |
| `GET /accounts` | 403 | ✅ |
| `DELETE /accounts/{id}` | 403 | ✅ |
| `POST /accounts`, `POST /accounts/login` | 403 | ✅ (uso interno do Auth) |

Decisões:
- **Duas camadas** (defesa em profundidade): se alguém esquecer de configurar uma rota no gateway, o account ainda bloqueia.
- **Header forjado não funciona**: o gateway sempre apaga `id-account`/`role-account` vindos do cliente e reescreve com o que está no token.
- **Chamada sem headers = interna**. O Auth chama o account direto pela rede interna (Feign) para registrar e logar; os serviços não são expostos fora do cluster, só o gateway.

## Como reproduzir

```bash
# docker/.env com ADMIN_EMAIL e ADMIN_PASSWORD preenchidos
docker compose -f docker/compose.yml up --build -d
```
Depois rode os blocos de RBAC de [`docs/requests.http`](../requests.http).

## Evidência

Validação no compose (2026-11-13), em cima de um banco que já tinha contas, para testar também a migration:

| Cenário (pelo gateway) | Resultado |
|---|---|
| role no JWT: usuária comum / admin | `user` / `admin` |
| user: listar contas | 403 |
| user: ver a própria conta / a de outra pessoa | 200 / 403 |
| user: apagar outra conta | 403 |
| user: `POST /accounts` e `POST /accounts/login` | 403 / 403 |
| user com header forjado `role-account: admin` | 403 |
| admin: listar (1 admin + 2 users), ver e apagar outra conta | 200 / 200 / 204 |
| sem token: listar | 401 |
| register continua aberto | 201 |

No Grafana (dashboard "PMA26 - Visão geral", painel "Respostas por status"), os 403 aparecem separados dos 401.
