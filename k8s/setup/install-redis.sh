#!/usr/bin/env bash
# Install Redis in Leader-Follower mode via Bitnami Helm chart
set -euo pipefail # Strict mode

NAMESPACE="ironhack-project-2"
RELEASE="redis"
REPLICA_COUNT=2

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create the namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Generate a random password instead of hardcoding one
# But the vote app and worker app never use a password for Redis 
# REDIS_PASSWORD="$(openssl rand -base64 20)"

# kubectl create secret generic "${RELEASE}-credentials" \
#   --namespace "$NAMESPACE" \
#   --from-literal=redis-password="$REDIS_PASSWORD" \
#   --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$RELEASE" bitnami/redis \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set architecture=replication \
  --set auth.enabled=false \
  --set replica.replicaCount="$REPLICA_COUNT" \
  --wait --timeout=5m

echo ""
echo "==> Redis (Leader-Follower) installed in namespace '$NAMESPACE'."
echo ""
echo "    Pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE"
echo ""
echo "    Redis Leader service:"
kubectl get svc -n "$NAMESPACE" "${RELEASE}-master"
echo ""
echo "    Redis Follower service:"
kubectl get svc -n "$NAMESPACE" "${RELEASE}-replicas"
echo ""
# echo "==> Credentials stored in Secret '${RELEASE}-credentials' (namespace $NAMESPACE)."
# echo "    Retrieve later with:"
# echo "    kubectl get secret ${RELEASE}-credentials -n $NAMESPACE -o jsonpath='{.data.redis-password}' | base64 -d; echo"
# echo ""
echo "    App connection strings:"
echo "    Write: ${RELEASE}-master.${NAMESPACE}.svc.cluster.local:6379"
echo "    Read:  ${RELEASE}-replicas.${NAMESPACE}.svc.cluster.local:6379"
