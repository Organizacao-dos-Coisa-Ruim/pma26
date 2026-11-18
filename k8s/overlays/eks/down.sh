#!/usr/bin/env bash
# DESTRÓI o ambiente criado pelo up.sh, na ordem certa (issue #60):
#   1. namespace pma26 -> apaga o LoadBalancer (se ficar, a VPC não pode ser apagada)
#   2. node group -> 3. cluster -> 4. RDS e o security group/subnet group dele -> 5. pilha da VPC (NAT incluso)
# As roles IAM ficam (não custam nada); DELETE_ROLES=1 apaga também.
#
#   ./k8s/overlays/eks/down.sh
#
# Depois, confira no console (EC2 > Load Balancers, NAT Gateways; RDS; EKS) que não sobrou nada.
set -uo pipefail   # sem -e: continua mesmo se algo já foi apagado

export AWS_REGION="${AWS_REGION:-us-east-1}"
NAME="${NAME:-pma26}"
DIR="$(cd "$(dirname "$0")" && pwd)"
step() { echo; echo "==> $*"; }

step "1/5 Kubernetes (LoadBalancer)"
if aws eks describe-cluster --name "$NAME" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$NAME" >/dev/null
  kubectl delete namespace pma26 --wait=true --timeout=5m
fi

step "2/5 Node group"
if aws eks describe-nodegroup --cluster-name "$NAME" --nodegroup-name "$NAME-nodes" >/dev/null 2>&1; then
  aws eks delete-nodegroup --cluster-name "$NAME" --nodegroup-name "$NAME-nodes" >/dev/null
  aws eks wait nodegroup-deleted --cluster-name "$NAME" --nodegroup-name "$NAME-nodes"
fi

step "3/5 Cluster"
if aws eks describe-cluster --name "$NAME" >/dev/null 2>&1; then
  aws eks delete-cluster --name "$NAME" >/dev/null
  aws eks wait cluster-deleted --name "$NAME"
fi

step "4/5 RDS"
if aws rds describe-db-instances --db-instance-identifier "$NAME-db" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$NAME-db" --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$NAME-db"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$NAME-db-subnets" 2>/dev/null
VPC_ID=$(aws cloudformation describe-stacks --stack-name "$NAME-vpc" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text 2>/dev/null)
if [ -n "$VPC_ID" ]; then
  DB_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$NAME-db-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [ "$DB_SG" != None ] && aws ec2 delete-security-group --group-id "$DB_SG"
fi
rm -f "$DIR/rds.env"

step "5/5 VPC (CloudFormation, inclui os NAT Gateways)"
if aws cloudformation describe-stacks --stack-name "$NAME-vpc" >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "$NAME-vpc"
  aws cloudformation wait stack-delete-complete --stack-name "$NAME-vpc" \
    || echo "A pilha da VPC não foi apagada: veja no console se sobrou um LoadBalancer ou ENI na VPC."
fi

if [ "${DELETE_ROLES:-}" = 1 ]; then
  step "Roles IAM"
  for r in "$NAME-cluster-role:AmazonEKSClusterPolicy" \
           "$NAME-node-role:AmazonEKS_CNI_Policy AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly"; do
    name=${r%%:*}
    for p in ${r#*:}; do aws iam detach-role-policy --role-name "$name" --policy-arn "arn:aws:iam::aws:policy/$p" 2>/dev/null; done
    aws iam delete-role --role-name "$name" 2>/dev/null
  done
fi

echo
echo "Pronto. Confira no console que não há EKS, EC2, RDS, Load Balancer nem NAT Gateway em $AWS_REGION."
