# Custos, PaaS e SLA

Rubrica: **PaaS & Custos & SLA (10%)**. Issues #83–#87.

!!! warning "Preços"

    Valores **on-demand em `us-east-1` (N. Virginia)**, em USD, considerando 730 h/mês. Conferir e salvar a
    estimativa no [AWS Pricing Calculator](https://calculator.aws/){:target='_blank'} (#84). O custo real
    medido no Cost Explorer entra na seção [Custo real](#custo-real) depois dos testes no EKS (#85).

## Dimensionamento

Os `requests` dos manifests ([Kubernetes](kubernetes.md)) definem quanto de CPU e memória o cluster precisa reservar:

| Pods | CPU (request) | Memória (request) |
|------|--------------:|------------------:|
| auth, account, exchange (1 réplica cada) | 3 × 250m | 3 × 384 Mi |
| gateway, mínimo do HPA | 1 × 250m | 1 × 256 Mi |
| redis | 50m | 64 Mi |
| sistema (CoreDNS, aws-node, kube-proxy, metrics-server) | ~400m | ~400 Mi |
| **Total em repouso** | **~1,45 vCPU** | **~1,9 GiB** |
| gateway no máximo do HPA (+9 pods) | +2,25 vCPU | +2,25 GiB |
| **Total no pico do load test** | **~3,7 vCPU** | **~4,2 GiB** |

**Escolha: 2 nós `t3.medium`** (2 vCPU e 4 GiB cada, ~1,9 vCPU alocável), um em cada subnet privada (2 zonas de
disponibilidade). Isso dá ~3,8 vCPU alocáveis, que cobrem o pico. Um `t3.small` (2 GiB) não comporta 4 JVMs mais
as réplicas do gateway.

## Estimativa mensal (ligado 24/7)

| Serviço | Configuração | Preço | USD/mês |
|---------|--------------|-------|--------:|
| EKS (control plane) | 1 cluster | $0,10/h | 73,00 |
| EC2 (node group) | 2 × `t3.medium` | $0,0416/h cada | 60,74 |
| EBS (disco dos nós) | 2 × 20 GB gp3 | $0,08/GB-mês | 3,20 |
| RDS PostgreSQL | `db.t3.micro`, Single-AZ, 20 GB gp2 | $0,018/h + $0,115/GB-mês | 15,44 |
| NAT Gateway | 2 (um por subnet pública, criados pelo template da VPC) | $0,045/h cada + $0,045/GB | 65,70 |
| Load Balancer | 1 Classic LB (criado pelo `Service` `LoadBalancer`) | $0,025/h + $0,008/GB | 18,25 |
| IPv4 público | 2 do NAT + 2 do LB | $0,005/h cada | 14,60 |
| Transferência de dados | poucos GB (testes) | | ~1,00 |
| **Total** | | | **≈ 252** |

Isso dá **≈ $0,34 por hora** com o ambiente ligado.

**O que pesa:** o control plane do EKS (29%) e os NAT Gateways (26%) custam mais que os próprios servidores. Os dois
cobram **por hora de existência**, mesmo sem tráfego.

### Custo no projeto (uso real previsto)

O ambiente só precisa existir durante o setup, o load test, a gravação do vídeo e a demo:

| Uso | Horas | Custo |
|-----|------:|------:|
| Setup e testes do EKS | ~10 h | ~$3,40 |
| Load test e vídeo | ~4 h | ~$1,40 |
| Demo da apresentação | ~4 h | ~$1,40 |
| **Total** | **~18 h** | **~$6** |

Para isso ser verdade, **tudo é destruído ao fim de cada sessão**: cluster, node group, RDS, load balancer e a pilha
CloudFormation da VPC, que é a que contém os NAT Gateways. Parar o RDS não basta, porque o EKS e o NAT continuam
cobrando. Um alerta no **AWS Budgets** (#49) avisa se algo ficar ligado por engano (sugestão: alerta em $20).

### Como reduzir (se fosse produção)

| Medida | Economia | Custo da medida |
|--------|----------|-----------------|
| 1 NAT Gateway em vez de 2 | ~$36/mês | se a zona do NAT cair, os pods da outra zona perdem a saída para a internet |
| Nós **Spot** em vez de on-demand | ~60–70% dos nós | a AWS pode retomar a instância com 2 min de aviso; ok para serviços sem estado com 2+ réplicas |
| **Savings Plan / Reserved** (1 ano) | ~30–40% dos nós e do RDS | compromisso de uso |
| Ingress (AWS Load Balancer Controller + ALB) quando houver mais de um serviço exposto | 1 LB para vários serviços | mais um componente para manter |
| Desligar fora do horário de uso (ambiente de dev/teste) | proporcional | não serve para produção |

## Onde usamos PaaS

O critério é: **quem cuida da máquina, do sistema operacional e da atualização do software?** Quanto mais a
plataforma cuida, mais "PaaS" é o serviço.

| Serviço | Modelo | O que a plataforma faz por nós | O que ainda é nosso |
|---------|--------|-------------------------------|---------------------|
| **AWS EKS** | PaaS / CaaS (control plane gerenciado) | API server, etcd, alta disponibilidade e atualização do control plane | node group (tipo e quantidade de nós), manifests, HPA |
| **AWS RDS** | PaaS (DBaaS) | instalação, patches, backups automáticos, monitoramento, opção Multi-AZ | schema (Flyway), tamanho da instância |
| **Elastic Load Balancing** | PaaS | balanceamento, health check dos nós, alta disponibilidade | só declarar `type: LoadBalancer` |
| **GitHub Actions** | PaaS (CI/CD como serviço) | runners, cache, segredos | os workflows ([CI/CD](cicd.md)) |
| **Docker Hub** | PaaS (registry) | armazenamento e distribuição das imagens | tags e push |
| **GitHub Pages** | PaaS (hospedagem estática) | servir este site | o build do MkDocs |
| **AwesomeAPI** | SaaS (API externa) | cotações de moedas | o cache Redis para não depender dela a cada requisição |

**O que decidimos *não* usar como PaaS:**

- **Redis** roda como pod no cluster, e não no ElastiCache (~$12/mês o menor nó). É só cache: se perder os dados, a
  próxima consulta busca a cotação de novo. Pagar por alta disponibilidade gerenciada não compensa.
- **Prometheus/Grafana** ficam no Compose local, e não no Amazon Managed Prometheus/Grafana. Seria mais um custo fixo
  para um projeto acadêmico.

## SLA

### SLAs da AWS que usamos

| Serviço | SLA mensal da AWS |
|---------|------------------:|
| EKS (control plane) | 99,95% |
| Elastic Load Balancing | 99,99% |
| EC2 (nível de região, instâncias em 2+ zonas) | 99,99% |
| RDS **Single-AZ** | 99,5% |
| RDS **Multi-AZ** | 99,95% |

Uma requisição só funciona se **todos** esses componentes estiverem de pé. Ou seja, eles estão em série e as
disponibilidades se multiplicam:

| Arquitetura | Conta | Disponibilidade | Indisponibilidade/mês |
|-------------|-------|----------------:|----------------------:|
| RDS Single-AZ (a do projeto) | 0,9995 × 0,9999 × 0,9999 × 0,995 | **≈ 99,43%** | ≈ 4 h 10 min |
| RDS Multi-AZ | 0,9995 × 0,9999 × 0,9999 × 0,9995 | **≈ 99,88%** | ≈ 53 min |

O **RDS Single-AZ é o elo mais fraco**: sozinho, ele derruba o teto do sistema para menos de 99,5%. Ainda assim, o
nosso SLA não pode prometer mais do que o teto da infraestrutura, e a nossa própria aplicação também falha
(deploy, bug, pod reiniciando).

### Nosso SLA (SLO)

| Indicador (SLI) | Objetivo (SLO) | Como medimos |
|-----------------|----------------|--------------|
| **Disponibilidade** da API: % de requisições ao gateway sem erro 5xx | **99%** ao mês (≈ 7 h 18 min de falha tolerada) | Prometheus: `http_server_requests_seconds_count` do gateway, `status=~"5.."` / total |
| **Latência** das cotações (`GET /exchange/*`) | **p95 < 300 ms** | histograma `http_server_requests_seconds_bucket` (Grafana); no load test do kind, o p95 foi **30 ms** com 100 usuários |

**Por que 99% e não 99,9%:** com RDS Single-AZ, a infraestrutura sozinha já fica em ~99,4%. Prometer 99,9% exigiria:

1. **RDS Multi-AZ** (dobra o custo do banco: ~$15 → ~$30/mês);
2. **2+ réplicas de cada serviço** (hoje auth, account e exchange têm 1: se o pod cair, o serviço fica fora até o
   Kubernetes recriá-lo, ~1 min por causa da JVM). Mais nós, mais custo;
3. `minReplicas: 2` no HPA do gateway, que também resolve o pico de latência no início do [load test](load-test.md);
4. os 2 NAT Gateways (que o template já cria).

Isso mostra a troca entre **custo e disponibilidade**: cada "9" a mais custa réplicas, zonas e serviços Multi-AZ.

### O que já ajuda a disponibilidade

- **Probes** (`startup`, `readiness`, `liveness`): o Service só manda tráfego para pod pronto, e pod travado é reiniciado.
- **HPA** no gateway: aguenta picos sem erro (0 falhas em 30 mil requisições no load test).
- **Cache Redis**: se a AwesomeAPI ficar lenta ou fora, as cotações em cache continuam saindo por até 5 min.
- **Nós em 2 zonas**: a queda de uma zona derruba só metade dos nós.

## Custo real

*A preencher depois dos testes no EKS (#85): print do Cost Explorer filtrado pelo período, comparado com a estimativa acima.*
