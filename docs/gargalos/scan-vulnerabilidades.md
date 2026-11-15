# Gargalo: scan de vulnerabilidades (OWASP ZAP + Dependency-Check)

Issue #78 · responsável: Felipe · onde: CI do `pma26` (ZAP) e do `exchange-service` (Dependency-Check)

## Problema

Ninguém verificava a segurança do que o grupo entrega. Os testes conferem se a API **funciona**, não se ela
**resiste a entradas maliciosas**, se responde com os headers de proteção ou se as bibliotecas usadas têm falhas
conhecidas. Qualquer PR podia introduzir uma vulnerabilidade sem ninguém perceber.

## Solução

Dois scans automáticos no CI, que olham lados diferentes:

| Ferramenta | Tipo | O que analisa | Onde roda |
|------------|------|---------------|-----------|
| **OWASP ZAP** (API Scan) | DAST: ataca o sistema rodando | as rotas do gateway, com e sem token: injeção (SQL, comando, path traversal...), erros de servidor, headers de segurança, vazamento de informação | workflow do `pma26`, depois do smoke test, em todo PR e push |
| **OWASP Dependency-Check** | SCA: analisa as dependências | CVEs conhecidas (base da NVD) nas bibliotecas do `pom.xml` | workflow do `exchange-service`, quando o `pom.xml` muda e toda segunda-feira |

### Como o ZAP funciona aqui

```
smoke test OK ──► docker/zap-scan.sh ──► cria um usuário e faz login (JWT)
                                     ──► zap-api-scan.py lê docs/openapi.yaml (as rotas do gateway)
                                     ──► ataca cada rota com o token no header Authorization
                                     ──► relatório HTML/JSON (artefato do workflow)
                                     ──► qualquer alerta WARN/FAIL quebra o CI
```

- **`docs/openapi.yaml`**: o ZAP não descobre rotas de uma API REST sozinho (não há links para seguir); a especificação
  diz quais rotas existem e o formato dos corpos. Também serve como documentação da API.
- **Com token:** um usuário comum é criado e o JWT dele vai em todas as requisições, para o ZAP testar as rotas
  protegidas e não só os 401.
- **Sem `-I`:** todo alerta de nível WARN quebra o job. Se algum alerta for aceito pelo grupo, ele vai em
  `.zap/rules.tsv` com justificativa, em vez de ser ignorado em silêncio.
- **Sem segredos:** o ZAP não precisa de conta nem token, por isso funciona também em PRs vindos de fork.

## Evidência: o que o ZAP encontrou e o que foi corrigido

Primeiro scan (2026-11-15, sistema inteiro no compose, 54 URLs testadas): **3 alertas**. Relatório: [zap/antes.html](zap/antes.html).

| Alerta | Risco | Causa | Correção |
|--------|-------|-------|----------|
| *A Server Error response code was returned* em `POST /auth/register` | Baixo | O Account não validava o tamanho dos campos. Nome ou email com mais de 256 caracteres quebravam no Postgres (`value too long for type character varying(256)`); senha com mais de 72 bytes quebrava no BCrypt (`password cannot be more than 72 bytes`). O Account respondia 500 e o Auth devolvia 503 | `account-service`: validação no `AccountService.create`, devolve **400** |
| *X-Content-Type-Options Header Missing* (`/auth/login`, `/exchange/USD/BRL`) | Baixo | Sem esse header o navegador pode "adivinhar" o tipo do conteúdo e tratar JSON como HTML/script | `gateway-service`: `SecurityHeadersFilter` |
| *Cross-Origin-Resource-Policy Header Missing* (5 rotas) | Baixo | Outros sites podiam embutir as respostas da API | `gateway-service`: `SecurityHeadersFilter` |

O 503 é o achado mais importante: qualquer pessoa conseguia gerar **erros de servidor** à vontade, o que suja os
alertas de 5xx, consome recursos e esconde problemas reais. Os três casos foram reproduzidos à mão antes da correção
(`POST /auth/register` com nome de 300 caracteres, email de 300 caracteres e senha de 100 caracteres → 503 nos três).

**Correções:**
- **`gateway-service` → `SecurityHeadersFilter`:** um `WebFilter` que adiciona em **toda** resposta
  `X-Content-Type-Options: nosniff`, `Cross-Origin-Resource-Policy: same-origin`, `X-Frame-Options: DENY` e
  `Referrer-Policy: no-referrer`. É um `WebFilter` (e não um filtro de rota do Gateway) para cobrir também o
  `/health-check` do próprio gateway e as respostas 401/403 do `AuthorizationFilter`. Ele grava os headers em
  `beforeCommit`, para não serem sobrescritos pelo serviço de destino. A correção é feita no gateway porque ele é o
  único ponto de entrada: protege todos os serviços de uma vez, inclusive os que ainda vão ser criados.
- **`account-service` → `AccountService.create`:** limites de 256 caracteres para nome e email (o tamanho da coluna)
  e de 72 **bytes** para a senha (limite do BCrypt; em bytes porque `ç` ocupa 2 bytes em UTF-8). Valores maiores
  devolvem 400 com a mensagem do limite.

Segundo scan, com as correções: **0 alertas, 120 regras passando** (antes: 3 alertas, 118 passando).
Relatório: [zap/depois.html](zap/depois.html). Os três cadastros que davam 503 agora dão 400.

**O CI realmente quebra?** Sim. Rodando o mesmo scan direto contra o Account (sem passar pelo gateway, portanto sem
os headers), o `zap-api-scan.py` encontrou 3 alertas e saiu com código 2, o que falha o passo do workflow.

### Primeira execução no CI: 503 por rate limit da API externa

Na primeira execução no GitHub Actions, o ZAP quebrou o job com um único alerta: `GET /exchange/USD/BRL` →
**503**. O log do exchange mostrou a causa: `AwesomeAPI falhou para USD-BRL: status 429 Too Many Requests`. Os
runners do GitHub usam IPs compartilhados por milhares de projetos, e a AwesomeAPI pública limita esses IPs.

Não era vulnerabilidade: o Exchange fez o certo (API externa falhou → 503). Mas um CI que depende de uma API externa
fora do nosso controle fica instável. **Correção:** no CI, `docker/compose.ci.yml` troca a AwesomeAPI por um mock
(nginx com uma cotação fixa, `docker/ci/awesomeapi-mock.conf`). O scan continua atacando todo o nosso código e o
resultado fica determinístico. Com o mock, o smoke test também passou a conferir uma cotação com 200.

### O que o ZAP testou e não encontrou

Entre as 120 regras que passaram (lista completa no relatório):
- **Injeção:** SQL Injection (genérica e *time-based* para PostgreSQL, MySQL, Oracle, MsSQL), Remote OS Command
  Injection, Server Side Code Injection, Server Side Template Injection, XPath, XSLT, CRLF, XML External Entity;
- **XSS:** refletido, persistente e DOM;
- **Arquivos e servidor:** Path Traversal, Remote File Inclusion, Buffer Overflow, Format String Error;
- **CVEs famosas:** Log4Shell e Spring4Shell;
- **Vazamento de informação:** Application Error Disclosure, Debug Error Messages, Spring Actuator Information Leak,
  `.env` Information Leak, Cloud Metadata Potentially Exposed (`/latest/meta-data/`, usado para roubar credenciais na AWS).

## Evidência: Dependency-Check

Configurado no `exchange-service`: plugin `dependency-check-maven` 12.2.2 no `pom.xml` (quebra com CVSS ≥ 7, ignora
dependências de teste, falsos positivos em `dependency-check-suppressions.xml` com justificativa) e workflow
`.github/workflows/dependency-check.yml`.

**Status: aguardando a chave da NVD.** A primeira execução local, sem chave, falhou: a base da NVD tem 425.851
registros e, sem chave, a NVD bloqueia o download por rate limit (`NVD Returned Status Code: 429`). Com o secret
`NVD_API_KEY` configurado no repositório, o workflow roda; sem ele, o job só emite um aviso e termina, em vez de
quebrar todo PR.

**Cuidado com falso negativo:** rodando com a base incompleta (`-DautoUpdate=false` depois do 429), o plugin
terminou com `BUILD SUCCESS` em 3 segundos, sem ter checado quase nada. Um resultado verde só vale se a atualização
da base terminou sem erro, o que no CI é garantido pela chave.

> TODO: configurar `NVD_API_KEY`, rodar o workflow e registrar aqui as CVEs encontradas (ou a ausência delas).

## Como reproduzir

```bash
docker compose -f docker/compose.yml up --build -d
./docker/zap-scan.sh zap-report          # relatório em zap-report/zap-report.html

# dependências do exchange-service (a primeira execução baixa a base da NVD e demora)
cd api/exchange-service && ./mvnw dependency-check:check   # relatório em target/dependency-check-report.html
```

No GitHub: aba **Actions** → workflow "Smoke test (compose)" → artefato `zap-report`; e no `exchange-service`,
workflow "Dependency-Check" → artefato `dependency-check-report`.

## Limitações e próximos passos

- **CORS `*`:** o gateway aceita qualquer origem (`CORS_ALLOWED_ORIGINS`, padrão `*`). O ZAP não apontou porque só
  detecta isso em requisições com `Origin`, mas em produção (EKS) a variável deve ter só o domínio do front-end.
- **Sem HTTPS local:** o compose usa HTTP. No EKS, o TLS fica no load balancer; aí vale adicionar
  `Strict-Transport-Security` no `SecurityHeadersFilter`.
- **Dependency-Check só no `exchange-service`:** o mesmo plugin e workflow podem ser copiados para os outros serviços.
- **Auth sem limite de tentativas:** o ZAP API Scan não testa força bruta no login; um rate limit no gateway seria
  o próximo passo.

> TODO: anexar print do workflow do GitHub Actions com o passo do ZAP verde e o artefato do relatório.
