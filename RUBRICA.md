# RUBRICA — Projeto PMA 2026.2

> Fonte oficial: https://insper.github.io/platform/2026.2/exercises/project/
> Este arquivo é um resumo do enunciado. Em caso de divergência, **vale o site**.
> Atualize este arquivo sempre que o enunciado mudar.

## Objetivo

Construir uma aplicação web de **compra e venda de produtos** (e-commerce) em **microsserviços Spring Boot**, rodando na **AWS (EKS)**, com CI/CD, teste de carga, análise de custos e documentação em MkDocs.

- Grupo de **2 a 3 pessoas**.
- **Cada integrante implementa pelo menos um** dos microsserviços base (Gateway, Auth, Account, Exchange).
- Cada microsserviço vive no **seu próprio repositório** e entra no repositório principal (`pma26`) como **git submodule**.
- O sistema precisa estar **integrado e funcionando**: os serviços se comunicam e a aplicação fica acessível.

## Pesos

| # | Item | O que é | Peso |
|---|------|---------|------|
| 1 | Gateway | API Gateway, ponto de entrada único que roteia para os serviços | 5% |
| 2 | Auth | Autenticação e autorização: login, emissão e validação de token | 5% |
| 3 | Account | Cadastro e gestão dos dados do usuário | 5% |
| 4 | Exchange | Câmbio entre moedas | 5% |
| 5 | **Bottlenecks** | Gargalos identificados e resolvidos | **20%** |
| 6 | AWS | Setup da conta/CLI | 5% |
| 7 | EKS | Orquestração no Kubernetes gerenciado | 10% |
| 8 | CI/CD | Jenkins **ou** GitHub Actions | 10% |
| 9 | **Load Testing** | Teste de carga + HPA | **15%** |
| 10 | PaaS & Custos & SLA | Análise de custos | 10% |
| 11 | MkDocs | Documentação (IA permitida) | 10% |
| | | **Total** | **100%** |

> Os serviços em si valem só 20%. A maior parte da nota (80%) está em infra, gargalos, testes, custos e documentação. Priorize de acordo.

## Detalhamento por item

### 1–4. Microsserviços base
- **Gateway**: rota única de entrada; encaminha para auth, account, exchange, product, order etc.
- **Auth**: login, geração e validação de token (JWT); o gateway valida as rotas protegidas.
- **Account**: CRUD de usuário (nome, email, senha com hash).
- **Exchange**: cotação entre moedas para transações em moedas diferentes.
- Domínio do e-commerce (exercícios do curso): **Product API** e **Order API**.

### 5. Bottlenecks (20%)
- **Mínimo de 2 gargalos por integrante**, destacados na documentação.
- Opções sugeridas pelo curso:
  | Gargalo | Solução sugerida |
  |---------|------------------|
  | Cache | Redis / Memcached |
  | Observabilidade | Prometheus + Grafana (actuator + micrometer) |
  | Mensageria | Kafka / RabbitMQ |
  | Load Balancing | Nginx / HAProxy |
  | Scan de vulnerabilidades | SonarQube / OWASP ZAP / Snyk |
  | Pagamento | Stripe / PayPal (com tratamento de erro) |
  | AuthN/AuthZ | RBAC / OAuth2 |
- Cada gargalo precisa de: problema → solução → evidência (print, métrica, dashboard).

### 6. AWS (5%)
- Usuário IAM, access key, AWS CLI configurado (`aws configure`).

### 7. EKS (10%)
- VPC via CloudFormation (`amazon-eks-vpc-private-subnets.yaml`): **2 subnets públicas** (load balancers) e **2 privadas** (pods), na mesma região do cluster.
- Role do cluster EKS e role do Node Group, com estas policies: `AmazonEKS_CNI_Policy`, `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`.
- Node Group **só nas subnets privadas**.
- Banco no **RDS** (ou DynamoDB).
- Acesso via `aws eks update-kubeconfig --name <cluster>` + `kubectl`.
- ⚠️ Custo: instâncias EC2, EBS e load balancers. **Desligar/destruir o cluster quando não estiver usando.**

### 8. CI/CD (10%)
- Pipeline (Jenkins ou GitHub Actions): build → **push da imagem no Docker Hub** → **deploy no EKS**.

### 9. Load Testing (15%)
- Teste de carga (JMeter, Gatling, Locust ou loop com busybox) contra o gateway.
- **HPA** escalando o deployment do gateway por CPU (ex.: `kubectl autoscale deployment gateway --cpu-percent=50 --min=1 --max=10`).
- **Entregável: vídeo** mostrando o teste de carga rodando e o HPA escalando os pods.

### 10. PaaS & Custos & SLA (10%)
- Plano de custos no **AWS Pricing Calculator** cobrindo EKS, RDS e os demais serviços usados (Cost Explorer / Budgets).
- Descrever **onde e como** o grupo usou PaaS.
- Definir/discutir o SLA.

### 11. MkDocs (10%)
- Usar o template: https://hsandmann.github.io/documentation.template/

## Entregas

### Do grupo
- Repositório principal (`pma26`) com todos os serviços como submodules, integrado e funcionando.
- **Apresentação** (slides): introdução, arquitetura, demo (ao vivo se possível), desafios e gargalos, conclusão e próximos passos.
- **Vídeo de 1 a 2 minutos** apresentando o projeto e os gargalos implementados.

### Individual (cada aluno, link enviado pelo Blackboard)
Repositório próprio com MkDocs publicado, contendo:
1. Nome e grupo
2. Documentação das atividades (exercícios)
3. Código-fonte das atividades
4. Documentação do projeto
5. Código-fonte do projeto
6. Links para todos os repositórios usados
7. Destaque dos gargalos implementados (**mínimo 2 por pessoa**)
8. Apresentação do projeto
9. Vídeo da apresentação (1–2 min)

## Uso de IA (regra do curso)
- **Documentação:** permitido; revisar o que a IA gerou.
- **Implementação:** **parcialmente** permitido: boilerplate, sugestões de melhoria, correção de erros.
- **Obrigatório declarar** na documentação o que foi feito com IA e o que foi feito pelo grupo.
- **Todo integrante precisa saber explicar e defender qualquer parte do projeto**, inclusive as feitas com IA.

## Prazo
- Entrega no fim do curso. A data exata está no Blackboard.

## Checklist geral
- [ ] Gateway
- [x] Auth
- [x] Account
- [ ] Exchange
- [ ] Product / Order (domínio do e-commerce)
- [ ] Todos os serviços como submodules do `pma26`
- [ ] Docker Compose local subindo o sistema inteiro
- [ ] 2 gargalos por integrante, com evidência
- [ ] AWS CLI configurado
- [ ] EKS + VPC + Node Group + RDS
- [ ] CI/CD: Docker Hub → EKS
- [ ] Load test + HPA + vídeo
- [ ] Plano de custos + PaaS + SLA
- [ ] MkDocs (grupo e individual) com registro do uso de IA
- [ ] Slides + vídeo de 1–2 min
