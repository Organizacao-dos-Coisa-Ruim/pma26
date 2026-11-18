# pma26 · E-commerce em microsserviços

???+ info inline end "Edição"

    Insper · Plataformas, Microsserviços e APIs · 2026.2

Aplicação de compra e venda de produtos construída em **microsserviços Spring Boot**, com gateway único,
autenticação JWT, câmbio entre moedas, cache, observabilidade, CI/CD e deploy em **Kubernetes (AWS EKS)**.

## Grupo

Organização no GitHub: [Organizacao-dos-Coisa-Ruim](https://github.com/Organizacao-dos-Coisa-Ruim){:target='_blank'}

| Integrante | GitHub | Microsserviços | Gargalos |
|------------|--------|----------------|----------|
| Felipe Camêlo | [@felipecameloss](https://github.com/felipecameloss){:target='_blank'} | Exchange | [Cache com Redis](gargalos/cache-redis.md), [Scan de vulnerabilidades](gargalos/scan-vulnerabilidades.md) |
| Pedro Nadotti | [@Nadoutti](https://github.com/Nadoutti){:target='_blank'} | Gateway, Auth, Account | [Observabilidade](gargalos/observabilidade.md), [RBAC](gargalos/rbac.md) |
| Carlos | [@carloslifranco](https://github.com/carloslifranco){:target='_blank'} | Order *(em andamento)* | *a definir* |

## Entregas

- [x] Gateway, Auth, Account, Exchange
- [ ] Product / Order
- [x] Docker Compose subindo o sistema inteiro
- [x] Manifests Kubernetes testados no kind ([Kubernetes](kubernetes.md))
- [ ] 2 gargalos por integrante ([Gargalos](gargalos/index.md))
- [ ] AWS CLI, EKS, RDS ([EKS e AWS](eks.md))
- [ ] CI/CD: Docker Hub → EKS ([CI/CD](cicd.md))
- [ ] Load test + HPA + vídeo ([Load test](load-test.md)), executado no kind; faltam EKS e vídeo
- [ ] Custos, PaaS e SLA ([Custos](custos.md))
- [x] Documentação MkDocs (este site) e [registro do uso de IA](ia.md)
- [ ] Slides e vídeo de 1–2 min

## Repositórios

Cada microsserviço tem **dois repositórios**: a *interface* (`@FeignClient` + DTOs, uma lib que os outros serviços
importam) e o *service* (a implementação que roda em container). Todos entram no `pma26` como **git submodules**.

| Serviço | Interface | Implementação |
|---------|-----------|---------------|
| Principal | | [pma26](https://github.com/Organizacao-dos-Coisa-Ruim/pma26){:target='_blank'} (compose, k8s, docs, load test) |
| Gateway | | [gateway-service](https://github.com/Organizacao-dos-Coisa-Ruim/gateway-service){:target='_blank'} |
| Auth | [pma26-auth](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-auth){:target='_blank'} | [pma26-auth-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-auth-service){:target='_blank'} |
| Account | [pma-26-account](https://github.com/Organizacao-dos-Coisa-Ruim/pma-26-account){:target='_blank'} | [pma26-account-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-account-service){:target='_blank'} |
| Exchange | [pma26-exchange](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-exchange){:target='_blank'} | [pma26-exchange-service](https://github.com/Organizacao-dos-Coisa-Ruim/pma26-exchange-service){:target='_blank'} |

## Uso de IA

A documentação e partes do código tiveram auxílio de IA (Claude Code), como o curso permite. O que foi feito pela IA
e o que foi feito pelo grupo está em [Uso de IA](ia.md).
