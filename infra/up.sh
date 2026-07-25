#!/usr/bin/env bash
set -euo pipefail

# Usage: ./up.sh <your-name>      e.g.  ./up.sh richard
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ./up.sh <your-name>   (e.g. ./up.sh richard)"
  exit 1
fi
REGION="${AWS_REGION:-us-east-1}"

echo ">> Initialising Terraform..."
terraform init -input=false

echo ">> Building your EKS cluster. This takes ~15 minutes — go get a coffee."
terraform apply -auto-approve -var="student_name=${NAME}"

echo ">> Connecting kubectl to your cluster..."
aws eks update-kubeconfig --name "eks-${NAME}" --region "${REGION}"

echo ">> Done! Your nodes:"
kubectl get nodes