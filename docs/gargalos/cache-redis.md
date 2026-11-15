# Gargalo: cache das cotações com Redis (Exchange)

Issue #76 · responsável: Felipe · serviço: `exchange-service`

## Problema

Cada `GET /exchange/{from}/{to}` fazia uma chamada HTTP à [AwesomeAPI](https://docs.awesomeapi.com.br/api-de-moedas),
mesmo a cotação de um par sendo **igual para todos os usuários** e mudando só a cada ~30 segundos. Isso traz três problemas:

- **Latência:** toda requisição espera uma ida e volta pela internet até a API externa.
- **Dependência e rate limit:** a API é pública e gratuita, com limite de requisições. No load test (e com o HPA criando
  mais pods), o número de chamadas cresce junto com o tráfego, e qualquer lentidão ou bloqueio dela vira erro no Exchange.
- **Desperdício:** em 500 requisições de USD→BRL, as 500 iam buscar exatamente o mesmo valor.

## Solução

Guardar a cotação de cada par no **Redis** por **5 minutos** (TTL configurável). A primeira requisição do par busca
na API e grava no Redis; as seguintes leem do Redis até o TTL vencer.

```
                          hit (até 5 min)
ExchangeResource ─► ExchangeService ─► RateProvider.fetch() ──► Redis  "exchange:rates::USD-BRL"
                                        @Cacheable   │ miss
                                                     └──► AwesomeAPI ──► grava no Redis
```

| Peça | Onde | O que faz |
|------|------|-----------|
| `@Cacheable(cacheNames = "rates", key = "#from + '-' + #to", sync = true)` | `RateProvider.fetch` | a anotação que liga o cache ao método |
| `spring.cache.type: redis`, `time-to-live: 5m` | `application.yaml` | Redis como cache, com TTL (`EXCHANGE_CACHE_TTL`) |
| `CacheConfig` | `exchange-service` | `@EnableCaching`, fallback se o Redis cair e writer com lock |
| `redis:7.4-alpine` | `docker/compose.yml` | 64 MB, descarte LRU, sem persistência (é só cache) |
| contador `exchange_external_calls_total` | `RateProvider` | quantas vezes fomos **de fato** à API (é a evidência) |

### Decisões (e por quê)

- **O que vai para o cache é a `Rate` (sell, buy, date), não a resposta inteira.** O `id-account` muda por usuário e
  é colocado depois, fora do cache. A cotação é compartilhada; a resposta não.
- **`RateProvider` é uma classe separada do `ExchangeService`.** O cache do Spring funciona por *proxy*: só intercepta
  chamadas vindas de outra classe. Uma chamada `this.fetch()` dentro da mesma classe ignoraria o `@Cacheable`.
- **Erros não são cacheados.** Um 404 (par inexistente) ou 503 (API fora do ar) não vai para o Redis; a próxima
  requisição tenta de novo.
- **`sync = true` + writer com lock (*cache stampede*).** Com o cache vazio, 10 requisições simultâneas do mesmo par
  fariam 10 chamadas à API. Medimos isso: mesmo com `sync = true`, o writer padrão do Redis não usa lock e as 10
  passavam. Com `RedisCacheWriter.lockingRedisCacheWriter`, só uma busca na API e as outras esperam. A trava fica no
  próprio Redis, então vale também entre **vários pods** do exchange quando o HPA escalar.
- **Se o Redis cair, o Exchange não cai.** O padrão do Spring seria propagar o erro (500). O `LoggingCacheErrorHandler`
  só registra um aviso e a chamada segue direto para a API, como se não houvesse cache. O cache é otimização, não
  dependência obrigatória. Custo: enquanto o Redis está fora, cada requisição espera o timeout dele (500 ms).
- **TTL de 5 minutos:** a AwesomeAPI atualiza a cada ~30 s, mas para exibir preços num e-commerce 5 minutos de
  defasagem é aceitável. É configurável por `EXCHANGE_CACHE_TTL`.
- **Serialização Java padrão** (`Rate implements Serializable`) em vez de JSON: zero configuração e fácil de explicar.

## Problema extra encontrado durante a medição

Na primeira medição **sem cache**, 8 de 300 requisições deram `503`, todas no mesmo milissegundo, logo após a subida.
O log mostrou `'messageConverters' must not be empty`: uma **condição de corrida no Spring Cloud OpenFeign 5.0.2**.
Ele monta a lista de conversores JSON só na primeira chamada, criando a lista vazia e preenchendo depois; requisições
simultâneas pegavam a lista ainda vazia. Corrigido com o `FeignWarmup`, que monta a lista na subida, antes de o Tomcat
aceitar requisições. Isso apareceria em todo pod novo criado pelo HPA no load test.

> O `auth-service` usa a mesma versão do OpenFeign (cliente do Account), então provavelmente tem o mesmo problema
> no login sob carga. Não foi testado ainda.

## Como reproduzir

```bash
docker compose -f docker/compose.yml up --build -d
set -a; . docker/.env; set +a

# com cache (padrão)
./docker/load-exchange.sh 500 10 USD/BRL

# sem cache: mesma imagem, cache desligado por variável de ambiente
EXCHANGE_CACHE_TYPE=none docker compose -f docker/compose.yml up -d exchange
docker compose -f docker/compose.yml restart gateway   # o gateway guarda o IP antigo do exchange
./docker/load-exchange.sh 500 10 USD/BRL
```

Para começar com o cache vazio: `docker compose -f docker/compose.yml exec redis redis-cli flushall`.
Ver a chave e o TTL: `redis-cli --scan` e `redis-cli ttl "exchange:rates::USD-BRL"`.

**Grafana**, dashboard "PMA26 - Visão geral": painéis *Exchange: requisições x chamadas à AwesomeAPI* e
*Exchange: taxa de acerto do cache*, no fim da página.

| Métrica | PromQL |
|---------|--------|
| Chamadas à API externa | `sum(rate(exchange_external_calls_total{application="exchange"}[1m]))` |
| Requisições de cotação | `sum(rate(http_server_requests_seconds_count{application="exchange", uri="/exchange/{from}/{to}"}[1m]))` |
| Taxa de acerto | `sum(rate(cache_gets_total{cache="rates", result="hit"}[1m])) / sum(rate(cache_gets_total{cache="rates", result=~"hit\|miss"}[1m]))` |

## Evidência

Medição local (Docker Compose no Windows, 2026-11-15) pelo gateway, com JWT, usando `hey`: 500 requisições de
`GET /exchange/USD/BRL` com concorrência 10. Mesma imagem nos dois modos (`EXCHANGE_CACHE_TYPE=none` x `redis`),
300 requisições de aquecimento antes e **cache vazio no início** de cada medição. Mediana de 3 execuções:

| | sem cache | com Redis | diferença |
|---|---|---|---|
| **Chamadas à AwesomeAPI** | 500 | **1** | **−99,8%** |
| Requisições/s | 167 | **303** | +81% |
| Latência p50 | 48 ms | **21 ms** | −56% |
| Latência p95 | 112 ms | **42 ms** | −63% |
| Latência p99 | 170 ms | 287 ms | pior (ver abaixo) |
| Erros | 0 | 0 | |

<details><summary>As 3 execuções</summary>

| modo | req/s | p50 | p95 | p99 | chamadas à API |
|------|-------|-----|-----|-----|----------------|
| sem cache | 164,9 | 48 ms | 120 ms | 156 ms | 500 |
| sem cache | 167,3 | 48 ms | 113 ms | 175 ms | 500 |
| sem cache | 191,8 | 42 ms | 103 ms | 170 ms | 500 |
| Redis | 270,4 | 31 ms | 49 ms | 228 ms | 1 |
| Redis | 303,5 | 21 ms | 42 ms | 393 ms | 1 |
| Redis | 389,2 | 16 ms | 37 ms | 287 ms | 1 |

</details>

Leitura dos resultados:
- **O ganho principal é a dependência externa:** de 500 para 1 chamada. Com 5 minutos de TTL, o Exchange faz no máximo
  1 chamada por par a cada 5 minutos, independente do tráfego e do número de pods.
- **p99 pior com Redis:** a medição começa com o cache vazio, então a primeira leva de requisições espera o lock
  enquanto uma delas busca a cotação. É o custo de fazer 1 chamada em vez de 10. Com o cache já preenchido, o p99
  medido foi de 48 ms.
- **Por que a latência não cai mais:** o piso é o próprio caminho pelo gateway, que valida o JWT chamando o Auth
  (`POST /auth/solve`) em toda requisição. A AwesomeAPI responde rápido a partir do Brasil (a diferença das medianas
  é ~27 ms); o ganho seria maior com uma API externa mais lenta ou sob rate limit.
- **Redis fora do ar** (`docker compose stop redis`): o Exchange continuou respondendo `200` (~0,58 s por requisição,
  esperando o timeout do Redis), com o aviso `Cache 'rates' failed to get entry` no log. Ao religar o Redis,
  voltou a ~15 ms.

Testes automatizados (`ExchangeResourceIntegrationTest`, cache em memória no perfil `test`):
- duas cotações do mesmo par → 1 chamada à API (`segundaCotacaoVemDoCache`);
- 10 requisições simultâneas com a API lenta → 1 chamada (`requisicoesSimultaneasComCacheVazioChamamAApiUmaVez`);
- erro 404 não é cacheado → 2 chamadas (`erroNaoECacheado`).

> TODO: anexar prints do Grafana (painéis do Exchange) durante a carga, sem e com cache, e repetir no EKS.
