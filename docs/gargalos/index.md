# Gargalos

A rubrica pede **pelo menos 2 gargalos por integrante**, cada um com **problema → solução → evidência**.

| Gargalo | Integrante | Problema | Solução | Evidência |
|---------|------------|----------|---------|-----------|
| [Observabilidade](observabilidade.md) | Pedro Nadotti | sistema era uma caixa-preta: sem métricas de RPS, latência ou erros | Actuator + Micrometer → Prometheus → Grafana | dashboards do Grafana |
| [RBAC](rbac.md) | Pedro Nadotti | qualquer usuário logado listava e apagava contas de outros | papel `user`/`admin` no JWT, checado no gateway e no Account | cenários 403/200 no smoke test |
| [Cache com Redis](cache-redis.md) | Felipe Camêlo | toda cotação ia até a AwesomeAPI: lento, limitado e frágil | `@Cacheable` com Redis, TTL de 5 min | chamadas externas e latência antes/depois |
| [Scan de vulnerabilidades](scan-vulnerabilidades.md) | Felipe Camêlo | nenhuma verificação de segurança automatizada | OWASP ZAP (DAST) + OWASP Dependency-Check no CI | relatórios do ZAP antes/depois; 11 CVEs → 0 |
| [Load balancing](load-balancing.md) | Carlos | uma réplica só do gateway: ponto único de falha (caiu, o sistema todo caiu) | Nginx na frente de 3 réplicas do gateway (no EKS, ELB + HPA) | 100/100/100 na distribuição; queda de uma réplica: 100% de erro antes, 0 a 1 erro depois |
| [Mensageria (RabbitMQ)](mensageria.md) | Carlos | o POST /orders esperava o envio da confirmação ao cliente (~2 s) e prendia uma thread por pedido | fila `order-created` no RabbitMQ + order-worker separado, retry + DLQ, worker idempotente | POST de ~1 s para ~50 ms e 19 → 349 pedidos/s (protótipo); worker parado: pedidos aceitos e confirmados quando ele volta |
