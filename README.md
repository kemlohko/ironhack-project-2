# Multi-Tier Voting App on Amazon EKS

Deployment of the classic Docker Example Voting App (Python vote, Node.js result, .NET worker, Redis, PostgreSQL) to a production-like **Amazon EKS** cluster, reachable at a real domain through NGINX Ingress + external-dns, with automated **CI/CD** via GitHub Actions.

This is a follow-up to [Project 1 (Multi-AZ AWS Voting App on EC2)](../ironhack-project-1), migrating the same application from self-managed EC2 infrastructure to a managed Kubernetes platform.


## Architecture

```
              vote.<your-subdomain>.<your-domain>            result.<your-subdomain>.<your-domain>
                        |                                              |
                        v                                              v
              +---------------------------------------------------------------+
              |                    NGINX Ingress Controller                    |
              |               host-based routing, one shared ELB               |
              +-----------------------+-------------------+--------------------+
                                       |                   |
                                       v                   v
                              +---------------+   +-----------------+
                              | vote-service   |   | result-service   |
                              +-------+-------+   +--------+--------+
                                      |                      ^
                                      | write vote           | read tally
                                      v                      |
                              +---------------+       +----------------+
                              | redis-master   |      | postgres-read  |
                              | (leader)       |      | (replica)      |
                              +-------+-------+       +------------+---+
                                      |                             ^
                                      | pop vote                    | streaming replication
                                      v                             |
                              +---------------+                     | 
                              | worker (.NET)  |                    |
                              +-------+-------+                     |
                                      |                             |
                                      | write tally                 |
                                      v                             |
                              +----------------------------------------+
                              | postgres-postgresql-primary (write)    |
                              +----------------------------------------+

```

All inter-service communication uses short-form Kubernetes DNS (e.g. `redis-master`, `postgres-postgresql-primary`) since every component lives in the `ironhack-project-2` namespace — no hardcoded IPs.

## Skills Practiced

- Managed Kubernetes (Amazon EKS), StatefulSets, PersistentVolumeClaims
- Helm (Bitnami Redis + PostgreSQL charts, NGINX Ingress, external-dns)
- Redis leader-follower replication; PostgreSQL primary + read-replica streaming replication
- IAM Roles for Service Accounts (IRSA) for CSI drivers
- Ingress with host-based routing, DNS automation via external-dns / Route 53
- CI/CD with GitHub Actions (build → push → deploy → rollout verification)
- Reading Kubernetes/AWS failures layer by layer: storage → IAM → image registry → app config → DNS ownership → node-level networking

## Repository Structure

```
.
├── infra/
|   ├── main.tf
|   ├── variables.tf
|   ├── outputs.tf
|   ├── versions.tf
|   ├── up.sh                     # Spin up the cluster
|   ├── down.sh                   # Tear down the cluster
├── k8s/
│   ├── redis-values.yaml         
│   ├── postgres-values.yaml      
│   ├── vote-deployment.yaml
│   ├── vote-service.yaml
│   ├── result-deployment.yaml
│   ├── result-service.yaml
│   ├── worker-deployment.yaml
│   └── ingress.yaml
├── setup/
│   ├── install-redis.sh          # Helm values (architecture=replication, auth disabled)
│   └── install-postgres.sh       # Helm values (architecture=replication)
|   └── install-external-dns.sh
|   └── install-nginx-ingress.sh 
├── .github/
│   └── workflows/
│       └── ci-cd-pipeline.yml
└── README.md
```

## Prerequisites

- AWS account with EKS permissions
- `aws-cli`, `eksctl`, `kubectl`, `helm` installed locally
- Docker Hub account
- A Route 53 hosted zone
- GitHub repository secrets configured:
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `DOCKERHUB_USERNAME`
  - `DOCKERHUB_TOKEN`

## Setup

### 1. Cluster prerequisites (one-time, per cluster)
Provisioning the infratructure

```bash
./infra/up.sh <your-name> 
```
### 2. Cluster prerequisites (one-time, per cluster)

Before deploying anything stateful, three cluster-level pieces need to be in place — see Troubleshooting below for why each one bit us.

```bash
# Default StorageClass, so PVCs without an explicit storageClassName can bind
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# OIDC provider, required for IRSA
eksctl utils associate-iam-oidc-provider --cluster <your-cluster-name> --region <your-region> --approve

# EBS CSI Driver IAM role + add-on
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa --namespace kube-system \
  --cluster <your-cluster-name> --region <your-region> \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --override-existing-serviceaccounts --approve

eksctl create addon \
  --name aws-ebs-csi-driver --cluster <your-cluster-name> --region <your-region> \
  --service-account-role-arn arn:aws:iam::<account-id>:role/AmazonEKS_EBS_CSI_DriverRole \
  --force
```

**Node-to-node security group rule** — the shared cluster's node security group only opens ephemeral ports (1025–65535) between nodes, which breaks pod-to-pod traffic on port 80 whenever two pods land on different nodes. This needs to be fixed once, cluster-wide, in the Terraform that provisions the EKS module (see Troubleshooting → "the subtlest bug" below). If working from a shared cluster you don't own, confirm with your instructor whether this has been applied.

### 3. Redis (leader-follower)

```bash
./setup/install-redis.sh
```

Deploys via the plain `bitnami/redis` chart with `architecture=replication`. **Auth is intentionally disabled** (`auth.enabled=false`) — the app code (`worker`, `vote`) is written for the original unauthenticated Docker Compose stack and doesn't send a password; Redis is only reachable inside the cluster (ClusterIP), so the blast radius of no-auth is limited to the cluster network. See Troubleshooting for the reasoning.

Produces `redis-master` (read/write) and `redis-replicas` (read-only) Services.

### 4. PostgreSQL (primary + read replicas)

```bash
./setup/install-postgres.sh
```

Deploys via the plain `bitnami/postgresql` chart (not `postgresql-ha` — see Troubleshooting for why) with `architecture=replication`. Produces `postgres-postgresql-primary` (read/write) and `postgres-postgresql-read` (read-only) Services, with credentials stored in the `postgres-credentials` Secret.

### 5. Application tier

```bash
kubectl apply -f k8s/vote-deployment.yaml -f k8s/vote-service.yaml
kubectl apply -f k8s/worker-deployment.yaml
kubectl apply -f k8s/result-deployment.yaml -f k8s/result-service.yaml
```

- `vote` and `worker` point at `redis-master` (writes/pops from the list — not safe on a read replica).
- `worker` writes to `postgres-postgresql-primary`; `result` reads from `postgres-postgresql-read`.
- All three Services are `type: ClusterIP` — external access goes through Ingress only.

### 5. NGINX Ingress Controller

```bash
./setup/install-nginx-ingress.sh
```

Runs as cluster-level infrastructure in its own `ingress-nginx` namespace, separate from the app's `ironhack-project-2` namespace. The Ingress *resource* (routing rules) still has to live in `ironhack-project-2`, alongside the Services it routes to — Ingress can only reference Services in its own namespace.

### 6. external-dns

```bash
./setup/install-external-dns.sh
```

**`txtOwnerId` must be unique per student** on a shared hosted zone — this is what stops your external-dns instance from deleting another user's records (see Troubleshooting). `domainFilters` should match the actual Route 53 **zone name** (`<your-domain>`), not a subdomain prefix.

### 7. Ingress resource

```bash
kubectl apply -f k8s/ingress.yaml
```

Host-based routing — `vote.<your-subdomain>.<your-domain>` → `vote-service`, `result.<your-subdomain>.<your-domain>` → `result-service`, both on port 80, `path: /`. Host-based (not path-based `/vote` + `/result`) because the app's own HTML forms POST to `/`, which only works correctly when each app owns its own host root.

The `external-dns.alpha.kubernetes.io/hostname` annotation on the Ingress tells external-dns which Route 53 records to keep in sync automatically — no manual DNS console work after the first deploy.

### 8. Verify

```bash
kubectl get pods -n ironhack-project-2
kubectl get ingress -n ironhack-project-2
dig vote.<your-subdomain>.<your-domain>
dig result.<your-subdomain>.<your-domain>
curl -I http://vote.<your-subdomain>.<your-domain>/
curl -I http://result.<your-subdomain>.<your-domain>/
```

## CI/CD Pipeline

`.github/workflows/ci-cd-pipeline.yml` triggers on push to `main` with two dependent jobs:

**`build`** — checks out the repo, logs into Docker Hub, builds and pushes `vote`, `result`, and `worker` images tagged both `:latest` and `:${{ github.sha }}` (unique per-commit tags are what make `kubectl rollout undo` actually useful — see below).

**`deploy`** (`needs: build`) — configures AWS credentials, installs `eksctl` and `kubectl`, updates kubeconfig, patches the commit SHA into each deployment manifest, applies them, then waits on `kubectl rollout status` for all three deployments so the workflow fails loudly if a rollout doesn't actually come up healthy — not just if `kubectl apply` was accepted.

```yaml
- name: Update image tag in manifest
  run: |
    sed -i "s|image: <your-dockerhub-username>/vote:.*|image: <your-dockerhub-username>/vote:${{ github.sha }}|" k8s/vote-deployment.yaml
    sed -i "s|image: <your-dockerhub-username>/worker:.*|image: <your-dockerhub-username>/worker:${{ github.sha }}|" k8s/worker-deployment.yaml
    sed -i "s|image: <your-dockerhub-username>/result:.*|image: <your-dockerhub-username>/result:${{ github.sha }}|" k8s/result-deployment.yaml

- name: Apply Kubernetes Manifests
  run: kubectl apply -f k8s/

- name: Wait for rollout
  run: |
    kubectl rollout status deployment/vote-deployment -n ironhack-project-2 --timeout=120s
    kubectl rollout status deployment/worker-deployment -n ironhack-project-2 --timeout=120s
    kubectl rollout status deployment/result-deployment -n ironhack-project-2 --timeout=120s
```

**Deploy strategy note:** the manifest (in Git) is the single source of truth for the running image tag. `kubectl set image` / `kubectl patch` are useful for ad-hoc debugging or emergency rollback, but anything changed that way is temporary — the next `apply -f k8s/` will silently revert to whatever tag is written in the file. Keeping the tag *in* the file, updated by CI before every apply, avoids that drift entirely.

**Rollback:**
```bash
kubectl rollout history deployment/vote-deployment -n ironhack-project-2
kubectl rollout undo deployment/vote-deployment -n ironhack-project-2 --to-revision=<n>
```

## Stretch Goal: HTTPS with cert-manager

- Install `cert-manager` and configure a `ClusterIssuer` for Let's Encrypt.
- Add a `tls` block to `ingress.yaml` referencing the issued certificate for `vote.<your-subdomain>.<your-domain>` and `result.<your-subdomain>.<your-domain>`.
- Since real, resolvable hostnames are already in place (via external-dns), the HTTP-01 challenge should validate without extra DNS work.

## Troubleshooting Notes

### 1. Redis/Postgres PVCs stuck `Pending` — three stacked issues

**Symptom:** `helm install` times out; `kubectl get pvc` shows PVCs `Pending` with `STORAGECLASS <unset>`.

**Root cause chain:**
1. **EBS CSI Driver add-on: `Create failed`** in the EKS console. No IAM role was attached to its `ebs-csi-controller-sa` service account, so it couldn't authenticate to AWS to provision volumes.
2. **No default StorageClass.** Even once the driver works, a PVC with no explicit `storageClassName` needs *something* marked default to bind against — the cluster's `gp2` StorageClass existed but wasn't flagged default.
3. **ImagePullBackOff on `bitnami/postgresql-ha`.** Since August 2025, Bitnami restricted free image tags; the `postgresql-ha` chart (repmgr + Pgpool) pinned to a tag no longer available on the free tier. Fix: dropped `postgresql-ha` in favor of the plain `bitnami/postgresql` chart with `architecture=replication` — primary + read replicas without automatic failover, but auto-failover wasn't a hard requirement for this project.

**Fix, in order:** see Setup → 1. Cluster prerequisites above.

**Lesson — check in this order whenever a PVC is `Pending` on EKS:**
1. Is the relevant CSI driver add-on `Active` (not `Create failed`) in the EKS console?
2. Is there a default `StorageClass` (`kubectl get storageclass`)?
3. Does the driver's service account have an IAM role attached (`kubectl get sa <name> -n kube-system -o yaml`, look for `eks.amazonaws.com/role-arn`)?

`kubectl describe pvc <name>` and `kubectl get events --sort-by='.lastTimestamp'` show which layer is actually failing.

### 2. Worker crash-looping / result showing "relation votes does not exist"

**Symptom:** `result` logs repeat `Error performing query: error: relation "votes" does not exist`, forever.

**Root cause:** the `worker` service is the *only* one that runs `CREATE TABLE IF NOT EXISTS votes` on startup. If `worker` never successfully starts (stuck `Pending` on insufficient CPU, or crash-looping on a bad `DB_HOST`/`REDIS_HOST` value), the table never gets created, so `result` — which only ever runs `SELECT` — fails forever, even though `result` itself is completely healthy.

**Contributing config bugs found along the way:** Service name typos (`postgres-postgresql-master` instead of `-primary`), and env var name mismatches — the C# worker code reads `DB_USERNAME`/`DB_NAME`, not `DB_USER`/`DB_DATABASE`, so a wrong key silently falls back to the code's own defaults instead of erroring.

**Lesson:** when a downstream service reports "table/relation doesn't exist," check whether the *writer* service (not the failing reader) ever actually started successfully — `kubectl logs --previous` on a crash-looping pod shows the real exception, not just "Waiting for db."

### 3. Redis auth: `NOAUTH` vs. disabling auth entirely

The stock Docker Voting App's C# worker code never reads a `REDIS_PASSWORD` env var — it assumes an unauthenticated Redis, matching the original Docker Compose setup. Enabling `auth.enabled=true` on the Bitnami chart broke this silently (connects fine, every subsequent command fails with `NOAUTH`).

**Decision:** disabled Redis auth (`auth.enabled=false`) rather than patching the C# source and rebuilding. Redis is ClusterIP-only (no external exposure), and the project's stated goal was deploying the *existing* app, not hardening it — a deliberate, documented tradeoff rather than an oversight.

### 4. Ingress path routing → 404 on vote submission

**Symptom:** `/vote` page loads fine; clicking Cats/Dogs 404s.

**Root cause:** the vote app's HTML form POSTs to `/`, not `/vote` — it assumes it owns the root of its host. Path-based Ingress (`/vote` prefix stripped to the same Service) breaks this, since the browser's POST target doesn't match either Ingress rule.

**Fix:** switched to **host-based routing** (`vote.<your-subdomain>.<your-domain>`, `result.<your-subdomain>.<your-domain>`, each with `path: /`) instead of path-based routing on a single host — each app now genuinely owns `/` on its own subdomain, no rewrite tricks needed.

### 5. external-dns fighting another user's instance over shared DNS records

**Symptom:** `vote.<your-subdomain>.<your-domain>` and `result.<your-subdomain>.<your-domain>` flapped between resolving and `NXDOMAIN`; external-dns logs showed the *exact same* CREATE/DELETE pairs repeating every sync cycle, forever, including deleting another user's `<classmate>.eks.<your-domain>` record each cycle.

**Root cause:** `<your-domain>` is a shared cohort hosted zone. Without a unique `--txt-owner-id`, every student's external-dns instance treats other students' records as unowned and eligible for cleanup under `--policy=sync` — a multi-tenant ownership collision, not a code bug.

**Fix:** set a unique `txtOwnerId` (`<your-txt-owner-id>`) and scope `domainFilters` correctly. Note: `domainFilters` must match the actual **zone name** (`<your-domain>`), not a subdomain — setting it to `<your-subdomain>.<your-domain>` caused external-dns to find *zero* matching zones and silently manage nothing, logging "all records up to date" while doing nothing at all.

**Lesson:** "no changes" in external-dns logs is ambiguous — it means either genuinely in sync, *or* zero matching zones found. Always confirm with `kubectl logs ... | grep -i zone` that a zone was actually discovered before trusting "up to date."

### 6. The subtlest bug: a 504 that came and went — node security group gap

**Symptom:** `result` always worked; `vote` 504'd intermittently, with zero code changes, correlating with which node the pod happened to be scheduled on.

**Root cause:** the shared cluster's Terraform (`terraform-aws-modules/eks/aws` v20, with the module's default "recommended" node security group rules) only opens **ephemeral ports (1025–65535)** between nodes. Container traffic on port 80 has no matching rule. When both the Ingress Controller and the app pod land on the *same* node, traffic never crosses the ENI, so the missing rule never applies — the moment the app pod is scheduled onto a *different* node, cross-node traffic on port 80 is silently dropped at the security group.

**Fix (Terraform, cluster-level):**
```hcl
module "eks" {
  # ...
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
}
```

**Lesson:** if a service works or fails depending on which node a pod lands on, with identical config either way, suspect the node security group before anything in Kubernetes — `kubectl` never sees a security group drop; it just looks like a generic upstream timeout.

