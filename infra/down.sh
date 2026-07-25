#!/usr/bin/env bash
set -euo pipefail

# Usage: ./down.sh <your-name>     e.g.  ./down.sh richard
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ./down.sh <your-name>   (e.g. ./down.sh richard)"
  exit 1
fi

# IMPORTANT: Kubernetes "LoadBalancer" services create AWS load balancers that
# Terraform doesn't know about. If you leave them, "terraform destroy" gets stuck
# trying to delete the network. So we delete them first.
echo ">> Removing any LoadBalancer services (Terraform can't see these)..."
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  for svc in $(kubectl get svc -n "$ns" \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    echo "   deleting service '$svc' in namespace '$ns'"
    kubectl delete svc "$svc" -n "$ns" || true
  done
done
sleep 20   # give AWS a moment to actually delete the load balancers

echo ">> Destroying all cluster infrastructure..."
terraform destroy -auto-approve -var="student_name=${NAME}"

echo ">> Done. Everything is gone. Your bill for this cluster is now \$0."