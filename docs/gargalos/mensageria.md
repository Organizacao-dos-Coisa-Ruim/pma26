# Gargalo: mensageria com RabbitMQ (Order)

Integrante: **Carlos**. Issue #77. Serviços: `order-service` (API e worker, mesma imagem) e a interface `order`.

## Problema

Criar um pedido não é só gravar no banco: depois vem a **confirmação ao cliente** (e-mail, recibo), que é lenta
porque depende de um serviço externo. Se ela roda dentro do `POST /orders`:

- **Latência:** o cliente espera o envio inteiro (simulado em 2 s) para saber que o pedido foi aceito.
- **Teto de vazão preso às threads HTTP:** cada pedido segura uma thread do Tomcat durante o envio. Com 200 threads
  e 2 s por pedido, o Order não passa de ~100 pedidos/s, e as outras rotas do Order disputam as mesmas threads.
- **Acoplamento de falhas:** se o envio da confirmação falha, a criação do pedido falha junto.

> O envio da confirmação é **simulado** (um log e uma espera de `pma.order.confirmation.delay`, padrão 2 s). Trocar
> por um provedor de e-mail real não muda o gargalo, que é ter trabalho lento dentro da requisição.

## Solução

O `POST /orders` grava o pedido como **`PENDENTE`**, publica o id dele na fila **`order-created`** do RabbitMQ e
responde na hora. Um **order-worker** consome a fila, envia a confirmação e marca o pedido como **`CONFIRMADO`**,
preenchendo `confirmedAt`.

```
                    1. grava PENDENTE                          4. markConfirmed (CONFIRMADO + confirmedAt)
POST /orders ──► order (API) ──► Postgres ◄────────────────────────────────────┐
     ▲              │ 2. publica o id do pedido                                   │
     │              ▼                                                             │
     │        fila "order-created" (durável) ─────────────────────────► order-worker (OrderCreatedListener)
     │              │ falhou 3 vezes                                      └► OrderConfirmation (envio lento)
     └── 3. 201 Created {"status":"PENDENTE"}
                    ▼
             fila "order-created.dlq"
```

| Peça | Onde | O que faz |
|------|------|-----------|
| RabbitMQ (`rabbitmq` no compose, `k8s/base/rabbitmq.yaml`) | `pma26` | o broker; painel de administração na porta 15672 |
| `OrderMessaging` | `order-service` | declara a fila durável `order-created` e a DLQ `order-created.dlq` (o Spring cria as duas ao conectar) |
| `OrderEventPublisher` | `order-service` | publica o id do pedido; se o RabbitMQ estiver fora, loga e **não** falha o POST |
| `OrderCreatedListener` | `order-service` (worker) | consome a fila; ignora pedido inexistente ou já confirmado |
| `OrderConfirmation` | `order-service` | envia a confirmação e marca `CONFIRMADO`; no modo síncrono roda dentro do POST |
| `status`, `confirmedAt` no `OrderOut` | interface `order` | o cliente acompanha o pedido em `GET /orders/{id}` |
| `order-worker` (compose, `k8s/base/order-worker.yaml`) | `pma26` | mesma imagem do Order com `pma.order.worker.enabled=true`; a API roda com o consumidor desligado |
| `docker/mq-test.sh` | `pma26` | script de evidência: latência do POST e worker fora do ar |

### Decisões (e por quê)

- **RabbitMQ em vez de Kafka.** O caso é uma fila de tarefas (cada pedido confirmado uma vez, por um consumidor), o
  uso típico do RabbitMQ. Kafka é melhor para log de eventos com replay e volumes muito maiores, e pede bem mais
  memória e configuração.
- **Worker separado da API, com a mesma imagem.** A API e o worker escalam de forma independente, e dá para parar o
  worker sem parar a API: os pedidos continuam sendo aceitos e as mensagens esperam na fila.
- **A mensagem leva só o id do pedido.** O worker relê o pedido no banco, que continua sendo a fonte da verdade.
- **Entrega "pelo menos uma vez" e worker idempotente.** O RabbitMQ pode entregar a mesma mensagem duas vezes. O
  worker só confirma pedido `PENDENTE`; repetida, a mensagem é ignorada.
- **Retry + DLQ.** Se a confirmação lançar exceção, o Spring tenta mais 2 vezes (1 s de espera) e depois rejeita a
  mensagem, que vai para a `order-created.dlq`. Uma mensagem com defeito não trava o worker num loop e fica guardada
  para análise.
- **Fila durável e mensagens persistentes:** sobrevivem a um restart do RabbitMQ.
- **`connection-timeout: 2s`:** com o RabbitMQ fora do ar, o POST não fica preso os 60 s padrão esperando conexão.
- **Modo síncrono mantido para medir** (`ORDER_CONFIRMATION_ASYNC=false`): o "antes" do gargalo, com a mesma imagem.

### Limitação conhecida

Se o RabbitMQ estiver fora do ar no momento do POST, o pedido é criado (201) mas o evento não é publicado, e o pedido
fica `PENDENTE` até alguém reprocessar. A solução seria um *outbox*: gravar "evento pendente" no banco junto com o
pedido e um job que republica o que não chegou ao broker.

## Como reproduzir

```bash
docker compose -f docker/compose.yml up --build -d      # docker/.env com RABBITMQ_PASSWORD
set -a; . docker/.env; set +a
./docker/mq-test.sh                                      # latência do POST + worker fora do ar

# o "antes": confirmação dentro da requisição
ORDER_CONFIRMATION_ASYNC=false docker compose -f docker/compose.yml up -d order
./docker/mq-test.sh
```

O painel do RabbitMQ (http://localhost:15672) mostra, na aba *Queues*, a `order-created` enchendo enquanto o worker
está parado e esvaziando quando ele volta, além da `order-created.dlq`.

## Evidência

O que o `docker/mq-test.sh` verifica:

| Cenário | Resultado esperado |
|---------|--------------------|
| POST /orders no modo síncrono | ~2 s por pedido (o cliente espera a confirmação) |
| POST /orders no modo assíncrono | dezenas de ms; o pedido sai `PENDENTE` e vira `CONFIRMADO` logo depois |
| Worker parado, N pedidos criados | todos aceitos (201, `PENDENTE`); N mensagens esperando na fila |
| Worker religado | a fila esvazia e todos os pedidos ficam `CONFIRMADO` |

### Medição de referência (protótipo com a mesma arquitetura)

Durante o desenvolvimento, um protótipo da mesma solução (Order + fila RabbitMQ + consumidor, confirmação simulada
em **1 s**) foi medido no Docker Compose local em 2026-11-20 com o `hey` (200 pedidos, concorrência 20, mediana de 3
execuções, pelo gateway e com JWT). Os números mostram o efeito do padrão; a implementação final usa 2 s de envio
simulado, então o "antes" dela é ainda mais lento.

| | síncrono (antes) | assíncrono (fila) |
|---|---|---|
| **Latência do POST p50** | 1039 ms | **50 ms** (−95%) |
| **Latência do POST p95** | 1078 ms | **89 ms** |
| Pedidos/s aceitos | 19 | **349** |
| Erros | 0 | 0 |

Com carga alta (1500 pedidos, concorrência 300), o modo síncrono parou em ~172 pedidos/s, no teto das 200 threads do
Tomcat, e até o health-check do Order ficou 5× mais lento (p95 de 455 ms); no assíncrono, 381 pedidos/s e
health-check com p95 de 83 ms.

**Leitura:** com a fila, o cliente não espera mais o envio da confirmação, e a capacidade de aceitar pedidos deixa de
depender de quanto tempo a confirmação leva. O trabalho continua existindo: a fila absorve o pico e o worker drena no
ritmo dele. Se a fila crescer demais, escala-se o `order-worker` (mais réplicas), sem mexer na API.

> TODO: prints do painel do RabbitMQ e da saída do `mq-test.sh` com a implementação final.
