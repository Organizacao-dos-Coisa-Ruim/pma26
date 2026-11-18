#!/usr/bin/env bash
# Cria o ambiente inteiro na AWS e faz o deploy do sistema (rubrica: EKS 10%; issue #60).
# Segue o roteiro da rubrica: VPC por CloudFormation, roles do cluster e do node group, EKS com nós só
# nas subnets privadas, RDS PostgreSQL e gateway exposto por LoadBalancer.
#
#   ./k8s/overlays/eks/up.sh            # leva ~25 min (o EKS sozinho demora ~12 min)
#   ./k8s/overlays/eks/down.sh          # DESTRÓI tudo (rodar ao final de cada sessão)
#
# Pré-requisitos:
#   - AWS CLI configurado (aws configure) com um usuário IAM que possa criar EKS, EC2, RDS, IAM e CloudFormation
#   - kubectl
#   - k8s/overlays/eks/secrets.env preenchido (modelo: secrets.env.example)
#   - imagens no Docker Hub (CI dos services com DOCKERHUB_USERNAME/DOCKERHUB_TOKEN) e DOCKERHUB_USER definido
#
# Custo: ~US$ 0,34 por hora enquanto existir (docs/custos.md). O script pede confirmação antes de criar.
# Pode ser rodado de novo: cada etapa pula o que já existe.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
NAME="${NAME:-pma26}"
DOCKERHUB_USER="${DOCKERHUB_USER:?defina DOCKERHUB_USER (usuário do Docker Hub com as imagens gateway, auth, account, exchange)}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# template oficial da AWS indicado na rubrica: 2 subnets públicas + 2 privadas, NAT, rotas
VPC_TEMPLATE="https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml"

[ -f "$DIR/secrets.env" ] || { echo "falta $DIR/secrets.env (copie de secrets.env.example)"; exit 1; }
set -a; . "$DIR/secrets.env"; set +a
: "${DATABASE_PASSWORD:?preencha DATABASE_PASSWORD em secrets.env}"

step() { echo; echo "==> $*"; }
exists() { "$@" >/dev/null 2>&1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Conta AWS $ACCOUNT_ID, região $AWS_REGION, cluster $NAME, nós 2x $NODE_TYPE, imagens $DOCKERHUB_USER/*"
echo "Isto cria recursos PAGOS (~US\$ 0,34/h). Lembre de rodar down.sh ao terminar."
if [ "${YES:-}" != 1 ]; then
  read -r -p "Digite 'sim' para continuar: " ok
  [ "$ok" = sim ] || exit 1
fi

# --- 1. VPC ---------------------------------------------------------------------------------
step "1/7 VPC (CloudFormation: $NAME-vpc)"
if ! exists aws cloudformation describe-stacks --stack-name "$NAME-vpc"; then
  aws cloudformation create-stack --stack-name "$NAME-vpc" --template-url "$VPC_TEMPLATE" >/dev/null
  aws cloudformation wait stack-create-complete --stack-name "$NAME-vpc"
fi
out() { aws cloudformation describe-stacks --stack-name "$NAME-vpc" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
VPC_ID=$(out VpcId)
CONTROL_SG=$(out SecurityGroups)
ALL_SUBNETS=$(out SubnetIds)
# o template marca as privadas com a tag kubernetes.io/role/internal-elb e as públicas com kubernetes.io/role/elb
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=kubernetes.io/role/internal-elb" \
  --query 'Subnets[].SubnetId' --output text)
echo "VPC $VPC_ID, subnets privadas: $PRIVATE_SUBNETS"

# --- 2. IAM roles ---------------------------------------------------------------------------
step "2/7 IAM roles"
role() { # role <nome> <serviço que assume> <policies...>
  local name=$1 service=$2; shift 2
  if ! exists aws iam get-role --role-name "$name"; then
    aws iam create-role --role-name "$name" --assume-role-policy-document \
      "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$service\"},\"Action\":\"sts:AssumeRole\"}]}" >/dev/null
  fi
  for p in "$@"; do aws iam attach-role-policy --role-name "$name" --policy-arn "arn:aws:iam::aws:policy/$p"; done
  aws iam get-role --role-name "$name" --query Role.Arn --output text
}
CLUSTER_ROLE=$(role "$NAME-cluster-role" eks.amazonaws.com AmazonEKSClusterPolicy)
NODE_ROLE=$(role "$NAME-node-role" ec2.amazonaws.com \
  AmazonEKS_CNI_Policy AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly)

# --- 3. Cluster EKS -------------------------------------------------------------------------
step "3/7 Cluster EKS $NAME (~12 min)"
if ! exists aws eks describe-cluster --name "$NAME"; then
  aws eks create-cluster --name "$NAME" --role-arn "$CLUSTER_ROLE" \
    --resources-vpc-config "subnetIds=$ALL_SUBNETS,securityGroupIds=$CONTROL_SG" >/dev/null
fi
aws eks wait cluster-active --name "$NAME"
CLUSTER_SG=$(aws eks describe-cluster --name "$NAME" --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)

# --- 4. Node group (só subnets privadas) ----------------------------------------------------
step "4/7 Node group $NAME-nodes: 2x $NODE_TYPE nas subnets privadas (~3 min)"
if ! exists aws eks describe-nodegroup --cluster-name "$NAME" --nodegroup-name "$NAME-nodes"; then
  # shellcheck disable=SC2086
  aws eks create-nodegroup --cluster-name "$NAME" --nodegroup-name "$NAME-nodes" \
    --node-role "$NODE_ROLE" --subnets $PRIVATE_SUBNETS --instance-types "$NODE_TYPE" \
    --scaling-config minSize=2,maxSize=3,desiredSize=2 --disk-size 20 >/dev/null
fi
aws eks wait nodegroup-active --cluster-name "$NAME" --nodegroup-name "$NAME-nodes"

# --- 5. RDS PostgreSQL ----------------------------------------------------------------------
step "5/7 RDS PostgreSQL $NAME-db (db.t3.micro, ~6 min)"
if ! exists aws rds describe-db-subnet-groups --db-subnet-group-name "$NAME-db-subnets"; then
  # shellcheck disable=SC2086
  aws rds create-db-subnet-group --db-subnet-group-name "$NAME-db-subnets" \
    --db-subnet-group-description "subnets privadas do $NAME" --subnet-ids $PRIVATE_SUBNETS >/dev/null
fi
# security group do banco: só aceita 5432 vindo do security group do cluster (os nós e pods usam esse SG)
DB_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$NAME-db-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$DB_SG" = None ]; then
  DB_SG=$(aws ec2 create-security-group --group-name "$NAME-db-sg" --description "Postgres do $NAME" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 5432 \
    --source-group "$CLUSTER_SG" >/dev/null
fi
if ! exists aws rds describe-db-instances --db-instance-identifier "$NAME-db"; then
  aws rds create-db-instance --db-instance-identifier "$NAME-db" --engine postgres \
    --db-instance-class db.t3.micro --allocated-storage 20 \
    --db-name store --master-username store --master-user-password "$DATABASE_PASSWORD" \
    --db-subnet-group-name "$NAME-db-subnets" --vpc-security-group-ids "$DB_SG" \
    --no-publicly-accessible --no-multi-az --backup-retention-period 0 >/dev/null
fi
aws rds wait db-instance-available --db-instance-identifier "$NAME-db"
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier "$NAME-db" --query 'DBInstances[0].Endpoint.Address' --output text)
echo "DATABASE_HOST=$DB_HOST" > "$DIR/rds.env"   # lido pelo kustomization.yaml (fora do git)
echo "RDS em $DB_HOST"

# --- 6. kubectl -----------------------------------------------------------------------------
step "6/7 kubeconfig e metrics-server"
aws eks update-kubeconfig --name "$NAME" >/dev/null
kubectl get nodes
# no EKS o metrics-server original funciona (sem o --kubelet-insecure-tls do kind)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml >/dev/null

# --- 7. Deploy ------------------------------------------------------------------------------
step "7/7 Deploy do sistema (imagens $DOCKERHUB_USER/*)"
kubectl kustomize "$DIR" | sed "s#DOCKERHUB_USUARIO/#$DOCKERHUB_USER/#g" | kubectl apply -f -
kubectl -n pma26 rollout status deploy/account deploy/auth deploy/exchange deploy/gateway --timeout=10m

echo "Aguardando o endereço do LoadBalancer..."
until LB=$(kubectl -n pma26 get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') && [ -n "$LB" ]; do sleep 10; done
echo
echo "Gateway: http://$LB:8080   (o DNS pode levar 1-3 min para responder)"
echo "Smoke test: GATEWAY=http://$LB:8080 ./docker/smoke-test.sh"
echo "Load test:  HOST=http://$LB:8080 NETWORK=host ./load/run.sh"
echo "AO TERMINAR: ./k8s/overlays/eks/down.sh"
