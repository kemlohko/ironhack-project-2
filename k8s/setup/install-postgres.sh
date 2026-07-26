#!/usr/bin/env bash
# Install PostgreSQL with Primary + Read Replicas (streaming replication)
# Note: no auto-failover here (that requires repmgr, in postgresql-ha chart,
# which needs Bitnami Secure Images access). If the primary goes down, a
# replica must be promoted manually.
set -euo pipefail # Strict mode

NAMESPACE="ironhack-project-2"
RELEASE="postgres"
DATABASE="voting"
READ_REPLICA_COUNT=2

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Generate a random password instead of hardcoding one
POSTGRES_PASSWORD="$(openssl rand -base64 20)"
REPLICATION_PASSWORD="$(openssl rand -base64 20)"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "${RELEASE}-credentials" \
  --namespace "$NAMESPACE" \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=replication-password="$REPLICATION_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$RELEASE" bitnami/postgresql \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set architecture=replication \
  --set auth.database="$DATABASE" \
  --set auth.existingSecret="${RELEASE}-credentials" \
  --set auth.secretKeys.adminPasswordKey="postgres-password" \
  --set auth.secretKeys.replicationPasswordKey="replication-password" \
  --set readReplicas.replicaCount="$READ_REPLICA_COUNT" \
  --wait --timeout=8m

echo ""
echo "==> PostgreSQL (Primary + Read Replicas) installed in namespace '$NAMESPACE'."
echo ""
echo "    Pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE"
echo ""
echo "    Primary service (read/write):"
kubectl get svc -n "$NAMESPACE" "${RELEASE}-postgresql-primary"
echo ""
echo "    Read-replica service (read-only):"
kubectl get svc -n "$NAMESPACE" "${RELEASE}-postgresql-read"
echo ""
echo "==> Credentials stored in Secret '${RELEASE}-credentials' (namespace $NAMESPACE)."
echo "    Retrieve later with:"
echo "    kubectl get secret ${RELEASE}-credentials -n $NAMESPACE -o jsonpath='{.data.postgres-password}' | base64 -d; echo"
echo ""
echo "    App connection strings:"
echo "    Write: ${RELEASE}-postgresql-primary.${NAMESPACE}.svc.cluster.local:5432/${DATABASE}"
echo "    Read:  ${RELEASE}-postgresql-read.${NAMESPACE}.svc.cluster.local:5432/${DATABASE}"