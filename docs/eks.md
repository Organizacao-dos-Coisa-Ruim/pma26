# EKS e AWS

!!! warning "A fazer"

    Issues #46–#60. Os manifests já estão prontos e testados no kind ([Kubernetes](kubernetes.md)); falta o overlay
    `k8s/overlays/eks` rodar num cluster de verdade.

Roteiro previsto (rubrica, item 7):

1. **AWS**: usuário IAM, access key, `aws configure` e alerta no AWS Budgets.
2. **VPC** via CloudFormation (`amazon-eks-vpc-private-subnets.yaml`): 2 subnets públicas (load balancer) e 2 privadas (pods).
3. **IAM roles** do cluster e do node group (`AmazonEKS_CNI_Policy`, `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`).
4. **Cluster EKS** e **node group** só nas subnets privadas.
5. **RDS PostgreSQL** nas subnets privadas.
6. `aws eks update-kubeconfig --name pma26`, metrics-server e `kubectl apply -k k8s/overlays/eks`.
7. Gateway exposto por **LoadBalancer**, smoke test e [load test](load-test.md) contra ele.
8. **Derrubar tudo** ao final (EKS, nós EC2, load balancer e RDS cobram por hora).
