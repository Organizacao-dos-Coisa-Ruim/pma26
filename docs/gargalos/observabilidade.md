# Gargalo: observabilidade (Prometheus + Grafana)

## Problema

Sem métricas, o sistema é uma caixa-preta. Não dá para saber quantas requisições por segundo ele aguenta,
qual serviço fica lento sob carga, se o banco virou o gargalo nem se o HPA escalou na hora certa. Também não há evidência
numérica para o load test.

## Solução

| Peça | O que faz |
|------|-----------|
| **Spring Boot Actuator + Micrometer** (em cada serviço) | Mede requisições HTTP (contagem, latência em histograma, status), JVM (heap, GC, threads), CPU, pool de conexões (HikariCP) e threads do Tomcat, e expõe tudo no formato do Prometheus |
| **Prometheus** | Coleta (*scrape*) as métricas de cada serviço a cada 5s e guarda como séries temporais |
| **Grafana** | Mostra as séries em dashboards; os dashboards e o datasource são provisionados por arquivo, então sobem prontos |

```
gateway ─┐  /gateway/actuator/prometheus
auth ────┼─ /actuator/prometheus  ◀── scrape 5s ── Prometheus ◀── PromQL ── Grafana (:3000)
account ─┘  /actuator/prometheus
```

Decisões:
- **O `/actuator` do auth e do account não é exposto**: o gateway só roteia `/auth/**` e `/accounts/**`, e o Prometheus coleta pela rede interna (no EKS, pelo DNS dos Services).
- **Histograma de latência** (`management.metrics.distribution.percentiles-histogram.http.server.requests`) em todos os serviços: permite calcular p95/p99 agregando réplicas, o que percentis pré-calculados não permitem.
- **Label `application`** colocado pelo Prometheus em cada job: é o que os dashboards usam para separar os serviços.
- Prometheus e Grafana publicados só em `127.0.0.1`; o Grafana exige login (senha via `GRAFANA_ADMIN_PASSWORD`).

## Métricas principais (PromQL)

| Painel | Consulta |
|--------|----------|
| Requisições/s | `sum by (application) (rate(http_server_requests_seconds_count{uri!~".*actuator.*"}[1m]))` |
| Latência p95 | `histogram_quantile(0.95, sum by (application, le) (rate(http_server_requests_seconds_bucket[1m])))` |
| Taxa de 5xx | `sum by (application) (rate(...{status=~"5.."}[1m])) / sum by (application) (rate(...[1m]))` |
| CPU | `process_cpu_usage` |
| Saturação | `tomcat_threads_busy_threads` vs `tomcat_threads_config_max_threads`; `hikaricp_connections_pending` |

## Como reproduzir

```bash
docker compose -f docker/compose.yml up --build -d
# gerar tráfego (docs/requests.http ou o script de load test) e abrir http://localhost:3000
```

## Evidência

Validação local (compose, 2026-11-13), com tráfego de teste (register, login, `GET /accounts` com e sem token):
- Prometheus: os 3 targets (`gateway`, `auth`, `account`) com estado `up`.
- Latência p95 medida por volta de 50–60 ms nos 3 serviços; gateway respondendo 200 (com token) e 401 (sem token).
- Grafana: datasource saudável e os dashboards "PMA26 - Visão geral" e "SpringBoot APM Dashboard" com dados.

> TODO: anexar prints do Grafana durante o load test e repetir no EKS.
