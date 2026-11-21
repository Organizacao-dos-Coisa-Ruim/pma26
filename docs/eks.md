# EKS e AWS

Rubrica: **AWS (5%)** e **EKS (10%)**. Issues #46–#60.

!!! warning "Ainda não executado"

    Os scripts estão prontos e os manifests foram testados no kind ([Kubernetes](kubernetes.md)), mas o ambiente na
    AWS ainda não foi criado. Faltam os pré-requisitos abaixo.

## Pré-requisitos

| O quê | Issue | Como |
|-------|-------|------|
| Usuário IAM + access key | #47 | Console da AWS → IAM → Users. Nunca use a conta root. |
| AWS CLI configurado | #48 | `winget install Amazon.AWSCLI` e `aws configure` (região `us-east-1`) |
| Alerta de orçamento | #49 | AWS Budgets → alerta em US$ 20 |
| Imagens no Docker Hub | #64, #66 | secrets `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN` na organização do GitHub; merge na `main` de cada service publica `<usuario>/<serviço>` |
| Segredos do deploy | | `k8s/overlays/eks/secrets.env` (modelo em `secrets.env.example`, fora do git) |
| Acesso do CI ao EKS | #66 | secrets `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` com **a mesma access key** usada no `up.sh` ([por quê](cicd.md#acesso-do-ci-ao-cluster)) |

## Subir e derrubar

Tudo com AWS CLI, seguindo o roteiro da rubrica, em dois scripts:

```bash
DOCKERHUB_USER=<usuario> ./k8s/overlays/eks/up.sh    # ~25 min, pede confirmação ("sim")
./k8s/overlays/eks/down.sh                           # destrói tudo, na ordem certa
```

| Etapa do `up.sh` | O que cria | Detalhe |
|------------------|------------|---------|
| 1. VPC | pilha CloudFormation `pma26-vpc` | template oficial `amazon-eks-vpc-private-subnets.yaml`: **2 subnets públicas** (load balancer, NAT) e **2 privadas** (nós, RDS) |
| 2. IAM | `pma26-cluster-role`, `pma26-node-role` | cluster: `AmazonEKSClusterPolicy`; nós: `AmazonEKS_CNI_Policy`, `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly` |
| 3. Cluster | EKS `pma26` | control plane gerenciado pela AWS (~12 min) |
| 4. Node group | `pma26-nodes`: 2× `t3.medium` | **só nas subnets privadas**; os nós não têm IP público ([dimensionamento](custos.md#dimensionamento)) |
| 5. Banco | RDS PostgreSQL `pma26-db` (`db.t3.micro`) | subnets privadas, sem acesso público; o security group só aceita a porta 5432 vinda do cluster |
| 6. kubectl | kubeconfig + metrics-server | `aws eks update-kubeconfig --name pma26` |
| 7. Deploy | `kubectl apply` do overlay `eks` | imagens do Docker Hub, `DATABASE_HOST` = endpoint do RDS, gateway como `LoadBalancer` |

Cada etapa **pula o que já existe**, então se algo falhar no meio basta rodar de novo.

O `down.sh` apaga na ordem inversa. O namespace vai **primeiro**: isso remove o load balancer, que senão impede
apagar a VPC. Por último sai a pilha da VPC, que leva junto os NAT Gateways, o item mais caro depois do control plane
([custos](custos.md)).

## Deploy contínuo

Depois do push da imagem no Docker Hub, o CI de cada service roda `kubectl set image` com a tag do commit, e o
Kubernetes faz **rolling update** sem downtime. Se o cluster não existir no momento (ele só fica de pé durante os
testes), o passo é pulado sem erro. O job está nos 6 services. O CI usa **a mesma access key de quem roda o
`up.sh`**, porque só quem cria o cluster tem acesso a ele por padrão ([por quê](cicd.md#acesso-do-ci-ao-cluster)).

## Evidências (a coletar)

- [ ] `kubectl get nodes -o wide` (nós sem IP externo, nas subnets privadas)
- [ ] Console: VPC com as 4 subnets; cluster `Active`; node group; RDS
- [ ] Smoke test pela URL do load balancer
- [ ] [Load test](load-test.md) no EKS + vídeo do HPA
- [ ] Cost Explorer depois da sessão ([custos](custos.md#custo-real))
