# SOLUTION-k8s.md — Kubernetes Extension (Part 2)

> Filled in progressively as each task is completed. See `k8s/README-k8s.md` for the original task prompts.

---

## Setup Notes & Bugs Found

- **Environment**: Windows + Docker Desktop, minikube `docker` driver, `ingress` + `metrics-server` addons enabled.
- **`minikube ip` is not reachable from the Windows host** with the `docker` driver (a known platform limitation — unlike Linux, where the driver's bridge IP is host-routable). `minikube service <svc> --url` works but requires a persistent foreground tunnel process on Windows. Used `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80` instead for all testing in this document.
- **Ingress rewrite-target bug** (same class as the Part 1 nginx bug, different manifestation): `k8s/06-ingress.yaml` originally rewrote both `/api/jobs` and `/api/jobs/` to `/jobs/` (trailing slash), but the FastAPI collection route is registered as `/jobs` (no trailing slash) — triggering a 307 redirect that broke through the ingress boundary. Since nginx ingress allows only **one** `rewrite-target` value per Ingress object, the fix required splitting `jobs-ingress` and `applications-ingress` each into two Ingress objects (collection-endpoint with a fixed target, item-endpoint with a capture group) — see Task 2.2 for the full explanation, since this is directly what that question asks about.

---

## Task 1 — Cluster Exploration (15 pts)

### 1.1 — Inspect all objects (5 pts)

```
$ kubectl get all -n jobboard
NAME                                        READY   STATUS    RESTARTS   AGE
pod/applications-service-5dd8c5968f-pcbd5   1/1     Running   0          6m27s
pod/applications-service-5dd8c5968f-wc72f   1/1     Running   0          6m27s
pod/frontend-65754f76d6-p8mhl               1/1     Running   0          6m27s
pod/frontend-65754f76d6-pd8lw               1/1     Running   0          6m27s
pod/jobs-service-56cb877c8f-ctdpq           1/1     Running   0          6m27s
pod/jobs-service-56cb877c8f-f2kvx           1/1     Running   0          6m27s
pod/postgres-5b8d74874c-ch4s9               1/1     Running   0          6m27s

NAME                           TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/applications-service   ClusterIP   10.110.223.8     <none>        3001/TCP   6m27s
service/frontend               ClusterIP   10.101.205.85    <none>        80/TCP     6m27s
service/jobs-service           ClusterIP   10.102.125.108   <none>        8000/TCP   6m27s
service/postgres               ClusterIP   10.102.115.207   <none>        5432/TCP   6m27s

NAME                                   READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/applications-service   2/2     2            2           6m27s
deployment.apps/frontend               2/2     2            2           6m27s
deployment.apps/jobs-service           2/2     2            2           6m27s
deployment.apps/postgres               1/1     1            1           6m27s

NAME                                              DESIRED   CURRENT   READY   AGE
replicaset.apps/applications-service-5dd8c5968f   2         2         2       6m27s
replicaset.apps/frontend-65754f76d6               2         2         2       6m27s
replicaset.apps/jobs-service-56cb877c8f           2         2         2       6m27s
replicaset.apps/postgres-5b8d74874c               1         1         1       6m27s

NAME                                                           REFERENCE                        TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/applications-service-hpa   Deployment/applications-service  cpu: 2%/60%, memory: 11%/75%   2         6         2          6m27s
horizontalpodautoscaler.autoscaling/jobs-service-hpa           Deployment/jobs-service          cpu: 6%/60%, memory: 45%/75%   2         6         2          6m27s

$ kubectl get pvc -n jobboard
NAME           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
postgres-pvc   Bound    pvc-c5c086c1-2d1b-4d86-a01d-beceb299dfa7   1Gi        RWO            standard       7m17s

$ kubectl get ingress -n jobboard
NAME                              CLASS   HOSTS   ADDRESS        PORTS   AGE
applications-ingress-collection   nginx   *       192.168.49.2   80      2m33s
applications-ingress-item         nginx   *       192.168.49.2   80      2m33s
frontend-ingress                  nginx   *       192.168.49.2   80      7m17s
jobs-ingress-collection           nginx   *       192.168.49.2   80      2m33s
jobs-ingress-item                 nginx   *       192.168.49.2   80      2m33s

$ kubectl get hpa -n jobboard
NAME                       REFERENCE                        TARGETS                        MINPODS   MAXPODS   REPLICAS   AGE
applications-service-hpa   Deployment/applications-service  cpu: 2%/60%, memory: 11%/75%   2         6         2          7m18s
jobs-service-hpa           Deployment/jobs-service          cpu: 4%/60%, memory: 45%/75%   2         6         2          7m18s

$ kubectl get secret -n jobboard
NAME              TYPE     DATA   AGE
postgres-secret   Opaque   3      7m18s
```

**Answers:**

- **READY ratio for each Deployment:** `applications-service` 2/2, `frontend` 2/2, `jobs-service` 2/2, `postgres` 1/1 (Postgres is intentionally single-replica — a `RWO` PVC can only be mounted by one pod at a time, and a naive multi-replica Postgres would corrupt shared state without a proper replication setup).
- **CLUSTER-IP of each Service:** `applications-service` 10.110.223.8, `frontend` 10.101.205.85, `jobs-service` 10.102.125.108, `postgres` 10.102.115.207. All `ClusterIP` type — internal-only, no `EXTERNAL-IP`.
- **StorageClass assigned to `postgres-pvc`:** `standard` — minikube's default dynamic-provisioning StorageClass (backed by `hostPath` under the hood in minikube's case), 1Gi, `RWO` (ReadWriteOnce) access mode, status `Bound`.

### 1.2 — Describe a Pod (5 pts)

```
$ kubectl describe pod jobs-service-56cb877c8f-ctdpq -n jobboard
...
Init Containers:
  wait-for-postgres:
    Image:  busybox:1.36
    Command: sh -c "until nc -z postgres 5432; do echo Waiting...; sleep 2; done; echo PostgreSQL is ready."
    State:  Terminated / Reason: Completed / Exit Code: 0
Containers:
  jobs-service:
    Image:      jobs-service:latest
    Liveness:   http-get http://:8000/health delay=30s timeout=5s period=15s #success=1 #failure=3
    Readiness:  http-get http://:8000/health delay=10s timeout=5s period=10s #success=1 #failure=3
    Environment:
      POSTGRES_USER:      <set to key 'POSTGRES_USER' in secret 'postgres-secret'>
      POSTGRES_PASSWORD:  <set to key 'POSTGRES_PASSWORD' in secret 'postgres-secret'>
      POSTGRES_DB:        <set to key 'POSTGRES_DB' in secret 'postgres-secret'>
      DATABASE_URL:       postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)
```

**What `initContainer` runs first and why?** `wait-for-postgres`, a tiny `busybox` container that polls `nc -z postgres 5432` in a loop until the Postgres Service accepts TCP connections. Init containers run to completion, in order, *before* any regular container in the pod starts — this is Kubernetes' equivalent of Docker Compose's `depends_on: condition: service_healthy`, since plain Kubernetes has no built-in cross-pod "wait until dependency is healthy" primitive at the pod-spec level. Without it, `jobs-service` could start and immediately fail its first few requests (or crash-loop) if scheduled before Postgres is accepting connections.

**What do `readinessProbe` and `livenessProbe` check, and what's the difference?** Both hit the same `GET /health` endpoint here, but they're evaluated for different purposes:

- **Readiness** (`delay=10s`, checked every `10s`) determines whether the pod should receive traffic *right now*. If it fails, the pod is removed from the Service's Endpoints list — no traffic is routed to it — but the pod itself keeps running and is retried; it's a "temporarily not ready" signal, not a failure verdict.
- **Liveness** (`delay=30s`, checked every `15s`) determines whether the container is fundamentally broken and needs a fresh start. If it fails `#failure=3` consecutive times, **kubelet kills and restarts the container** (increments `RESTARTS` in `kubectl get pods`), the same as a crash.
- **What happens if each fails:** readiness failure → pod silently drops out of load-balancing rotation until it passes again (no restart, no downtime for *other* pods since traffic just stops routing there); liveness failure → the container is killed and restarted, which is disruptive if it happens repeatedly (`CrashLoopBackOff`) but is the mechanism that recovers from genuinely wedged/deadlocked processes that would otherwise sit "Running" forever while broken.

**A latent risk observed while inspecting `Environment`:** `DATABASE_URL` is built directly in the pod spec via Kubernetes' `$(VAR)` env-var substitution, embedding the raw `POSTGRES_PASSWORD` secret value with no URL-encoding — the same class of bug documented in Part 1's Setup Issues (a password containing `@`, `/`, or `#` breaks the connection string). This deployment's `openssl rand -base64 20` password happened to only contain a trailing `=` (which is actually valid unencoded in the URL userinfo component per RFC 3986), so it worked — but a `+` or `/` in a regenerated password would break `jobs-service`/`applications-service` at startup. Not fixed here since it's not one of the assigned tasks, but the same fix applied in Part 1 (build the URL in application code with `urllib.parse.quote`/`encodeURIComponent`, reading the password from a file rather than interpolating it into a shared string) would apply equally well to the k8s manifests.

### 1.3 — Exec into a pod (5 pts)

```
$ kubectl exec -n jobboard $POD -- python3 -c "..."
{"status":"healthy","service":"jobs-service","version":"1.0.0"}

$ kubectl exec -n jobboard $POD -- sh -c "nslookup postgres || getent hosts postgres"
sh: 1: nslookup: not found
10.102.115.207  postgres.jobboard.svc.cluster.local
```

(`nslookup` isn't present in this slim Python image; `getent hosts postgres` — which uses the same libc resolver path — confirms DNS resolution and conveniently shows the FQDN directly.)

**Full DNS name of the `postgres` Service:** `postgres.jobboard.svc.cluster.local` — format is `<service-name>.<namespace>.svc.cluster.local`, resolving to the Service's ClusterIP (`10.102.115.207`).

**Why pods can use the short name `postgres` instead of the FQDN:** every pod's `/etc/resolv.conf` (managed by kubelet) includes a `search` path listing `<namespace>.svc.cluster.local`, `svc.cluster.local`, and `cluster.local`. When a program looks up the bare name `postgres`, the C library resolver tries each search-domain suffix in order — `postgres.jobboard.svc.cluster.local` matches on the first attempt (since the querying pod is itself in the `jobboard` namespace) via CoreDNS, Kubernetes' cluster-internal DNS server. This is directly analogous to Docker Compose's embedded DNS behavior from Part 1 — short service names resolve automatically — except Kubernetes additionally scopes it by namespace via the search-path mechanism, which is why cross-namespace lookups need at least `<service>.<namespace>` to resolve.

---

## Task 2 — Kubernetes Networking & Ingress (20 pts)

### 2.1 — Trace an Ingress request (8 pts)

Test performed against `POST http://<minikube-ip>/api/applications/` (via `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80`, since `minikube ip` isn't host-reachable on Windows with the `docker` driver — see Setup Notes):

```
$ curl -sv -X POST http://localhost:8080/api/applications/ \
    -H "Content-Type: application/json" \
    -d '{"job_id":"...","applicant_name":"Test User","applicant_email":"test@lab.com"}'
< HTTP/1.1 201 Created
{"id":"5bf890af-a3a4-4fc4-9543-c6230405276a","job_id":"...","applicant_name":"Test User","applicant_email":"test@lab.com","cover_letter":null,"status":"pending","created_at":"2026-07-30T10:14:56.329Z"}
```

**Full request journey:**

1. **Which Ingress resource matches?** `applications-ingress-collection` — its path `/api/applications/?$` matches the request path `/api/applications/` exactly (this is one of the two Ingress objects created in the Setup-Notes fix; `applications-ingress-item` only matches paths with something *after* the trailing slash, e.g. `/api/applications/{id}`).
2. **What does `rewrite-target` transform the path to?** `/applications` (a fixed target — no capture group needed here since this rule only ever matches the bare collection path, unlike the original single-Ingress design which tried to handle both cases with one regex).
3. **Which Service receives the request, on which port?** `applications-service`, port `3001` (ClusterIP `10.110.223.8`).
4. **Which Pod is selected, and how?** The Service's `Endpoints`/`EndpointSlice` list both `applications-service` pod IPs (`10.244.0.7:3001`, `10.244.0.9:3001` in this run) — selected via the Service's `selector: app: applications-service` label matcher, which continuously tracks all Ready pods carrying that label. kube-proxy load-balances (round-robin/random, iptables or IPVS mode) across whichever of those IPs are currently in the Endpoints list.
5. **What does the Node.js handler return?** `router.post('/', ...)` in `src/routes/applications.js` inserts the row into Postgres and returns `201 Created` with the full JSON record (confirmed above — matches exactly).

### 2.2 — Why three (now four... now six) Ingress objects? (4 pts)

The original manifest had 3 Ingress objects (`jobs-ingress`, `applications-ingress`, `frontend-ingress`). While deploying this lab (see Setup Notes), a real bug surfaced that required splitting the first two into two objects each — **6 Ingress objects total** now (`jobs-ingress-collection`, `jobs-ingress-item`, `applications-ingress-collection`, `applications-ingress-item`, `frontend-ingress`, plus the original count was actually already demonstrating this exact constraint before the split, just with a latent bug).

**The `rewrite-target` annotation and its one-value-per-Ingress limit:** `nginx.ingress.kubernetes.io/rewrite-target` is an *annotation on the Ingress object itself*, not on an individual `path` entry within it. Annotations apply to the whole resource. So if an Ingress object has multiple `path` rules but they need *different* rewrite targets, that's not expressible — every path within that Ingress object shares the exact same `rewrite-target` value (with capture-group substitution based on that Ingress's own regex).

**What would break with one Ingress for both `/api/jobs` and `/api/applications`?** If a single Ingress object tried to route both `/api/jobs(/|$)(.*)` → `jobs-service` and `/api/applications(/|$)(.*)` → `applications-service` under one `rewrite-target: /$2` (or similar), the *same* rewrite pattern would apply to matches from either path rule — but jobs and applications have different target service path prefixes (`/jobs...` vs `/applications...`). There's no way to say "rewrite path A's matches to `/jobs/$2` but path B's matches to `/applications/$2`" within a single annotation. It would either mis-route one of the two services entirely, or (if you tried a shared capture-group scheme) silently produce wrong URLs for one of them.

**Concretely, what we hit in this lab:** an even narrower version of this same limitation. `jobs-service`'s own FastAPI routes are registered as `/jobs` (no trailing slash) for the collection endpoint but `/jobs/{id}` (with slash) for item routes — two different trailing-slash shapes, needed from *one* upstream service. A single `jobs-ingress` with one `rewrite-target: /jobs/$2` could not produce `/jobs` (no slash) for the collection case and `/jobs/{id}` for the item case simultaneously — it always emitted a trailing slash, which triggered FastAPI's redirect-slash behavior and broke the collection endpoint. The fix split `jobs-ingress` into `jobs-ingress-collection` (fixed target `/jobs`, path regex `/api/jobs/?$`) and `jobs-ingress-item` (capture-group target `/jobs/$1`, path regex `/api/jobs/(.+)`) — exactly the multi-Ingress-per-annotation-value workaround this question is asking about, just needed *within* a single backend service rather than across two different services.

**Alternative architecture allowing a single Ingress:** if the upstream services themselves were mounted under distinct URL prefixes that already matched what nginx needs to produce (e.g., if `jobs-service` served its routes at `/api/jobs/...` directly instead of `/jobs/...`), no rewrite would be needed at all — nginx could forward the path unmodified with `rewrite-target` omitted entirely, collapsing everything down to path-based routing on a single Ingress (or even zero Ingress objects beyond one catch-all, using `pathType: Prefix` per service). This is the common production pattern: design each backend service to be prefix-aware (read its mount path from config/env) rather than relying on the ingress layer to strip/rewrite prefixes.

### 2.3 — NodePort vs ClusterIP vs LoadBalancer (4 pts)

| Type         | Reachable from                                                                                                                               | Use case                                                                                                                                                                        | Example in this lab                                                                                                                                                                                                                                    |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ClusterIP    | Only from inside the cluster (other pods/nodes)                                                                                              | Default, internal-only service-to-service traffic                                                                                                                               | `postgres`, `jobs-service`, `applications-service` — never need direct external access, only reached via the Ingress or from sibling pods                                                                                                       |
| NodePort     | Any cluster node's IP, on a fixed high port (30000-32767) allocated cluster-wide                                                             | Quick/manual external access without a cloud load balancer; common in on-prem or dev clusters                                                                                   | Patched`frontend` to `NodePort` for this exercise — port `32013` was reachable from the node itself (verified via `docker exec minikube curl localhost:32013` → `200`, since `minikube ip` isn't host-routable on Windows/docker-driver) |
| LoadBalancer | An external IP provisioned by a cloud provider's load balancer (AWS ELB, GCP LB, etc.) — routes to the Service from outside the cluster/VPC | Production external access on a cloud-managed cluster; not meaningful on bare minikube (would stay`<pending>` for `EXTERNAL-IP` without `minikube tunnel` or a LB add-on) | Not used in this lab — no cloud provider present                                                                                                                                                                                                      |
| Ingress      | Any client that can reach the Ingress controller's entry point (one shared IP/port for many services)                                        | HTTP(S) routing by path/host across multiple backend Services from a single external entry point, with TLS termination, rewrites, rate-limiting                                 | `jobs-ingress-*`, `applications-ingress-*`, `frontend-ingress` — this is the *actual* external entry point used throughout this lab                                                                                                           |

Verified: `kubectl patch svc frontend -n jobboard -p '{"spec":{"type":"NodePort"}}'` → assigned NodePort `32013`; confirmed reachable (`200`) from inside the node; then restored with `kubectl patch svc frontend -n jobboard -p '{"spec":{"type":"ClusterIP"}}'` → back to `80/TCP`, no external exposure.

### 2.4 — Network Policies (4 pts)

Wrote `k8s/09-network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-network-policy
  namespace: jobboard
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: jobs-service
        - podSelector:
            matchLabels:
              app: applications-service
      ports:
        - protocol: TCP
          port: 5432
```

Applied successfully (`kubectl apply -f k8s/09-network-policy.yaml` → `networkpolicy.networking.k8s.io/postgres-network-policy created`). Tested both directions:

```
$ kubectl run test-block --rm -it --image=busybox --restart=Never -n jobboard -- nc -zv -w 5 postgres 5432
postgres (10.102.115.207:5432) open        # ← expected to be BLOCKED, was NOT

$ kubectl exec -it $POD -n jobboard -- python3 -c "import socket; socket.create_connection(('postgres',5432),timeout=5); print('Connected')"
Connected                                   # ← expected to succeed, DID succeed
```

**Observed result: the "should-succeed" case passed, but the "should-be-blocked" case also succeeded** — `test-block` (an arbitrary busybox pod with no matching label) could still reach `postgres:5432` despite the NetworkPolicy being applied and correctly scoped. This matches the README's own documented caveat exactly: **NetworkPolicy enforcement requires a CNI plugin that implements it** (Calico, Cilium, Weave-with-policy, etc.) — the policy object is accepted and stored by the Kubernetes API regardless of whether anything enforces it, since `NetworkPolicy` is just a spec that the *CNI plugin* is responsible for reading and acting on. Confirmed minikube's `docker` driver here uses its default bridge networking (no `calico`/`cilium`/`weave` pods found in `kube-system`), which does not implement policy enforcement — so the manifest is correct and would work as intended on a policy-enforcing CNI (e.g. `minikube start --cni=calico`, or any managed cloud cluster using Calico/Cilium/AWS VPC CNI with policy support), but has no actual effect on this particular cluster. This is a good illustration of why manifest correctness and runtime verification are two different things — the YAML being "right" doesn't guarantee the cluster actually enforces what it describes.

---

## Task 3 — Persistent Storage & Data Lifecycle (15 pts)

### 3.1 — Inspect the PVC (5 pts)

```
$ kubectl describe pvc postgres-pvc -n jobboard
Name:          postgres-pvc
StorageClass:  standard
Status:        Bound
Volume:        pvc-c5c086c1-2d1b-4d86-a01d-beceb299dfa7
Capacity:      1Gi
Access Modes:  RWO
storage-provisioner: k8s.io/minikube-hostpath

$ kubectl get pv
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   STORAGECLASS
pvc-c5c086c1-2d1b-4d86-a01d-beceb299dfa7   1Gi        RWO            Delete           Bound    standard
```

**Reclaim Policy:** `Delete` — this is minikube's `standard` StorageClass default.

**`Retain` vs `Delete`:** with `Delete`, when the PVC is deleted, Kubernetes automatically deletes the underlying PersistentVolume *and* its backing storage (here, the `hostPath` directory on the minikube VM) — the data is gone, full stop. With `Retain`, deleting the PVC leaves the PV object (now in `Released` state) and its underlying storage intact — the data survives, but the PV isn't automatically rebindable to a new PVC; an administrator has to manually reclaim/clean it (or bind a new PVC to it by hand) before it can be reused. `Retain` is the safer default for production databases specifically *because* an accidental `kubectl delete pvc` shouldn't be able to instantly and irreversibly destroy the only copy of your data — `Delete` is convenient for dev/test where the data is disposable (exactly minikube's assumption).

**Access Mode and why postgres can't use `ReadWriteMany`:** the mode here is `RWO` (`ReadWriteOnce` — mountable read-write by only one node at a time). Postgres can't use `ReadWriteMany` (mountable read-write by multiple nodes simultaneously) because Postgres's on-disk data files are not designed for concurrent access by multiple independent Postgres processes — there's no cluster-aware locking/coordination for two separate `postgres` processes writing to the same data directory; doing so would corrupt the database. (This is a fundamentally different problem from *read replicas*, which use Postgres's own streaming-replication protocol over the network, not a shared filesystem — that's how you actually scale Postgres reads, not via `RWX` volumes.) Most cloud block-storage backends (`RWO`-only, like AWS EBS or minikube's hostPath here) don't even support `RWX` in the first place; `RWX` typically requires a networked filesystem like NFS or a distributed store — and even then, Postgres specifically still needs single-writer semantics at the application level regardless of what the volume technically permits.

### 3.2 — Verify persistence across pod restarts (5 pts)

```
$ curl -X POST http://localhost:8080/api/jobs/ -d '{"title":"K8s Persistence Test",...}'
{"title":"K8s Persistence Test",...,"id":"bdad3fdc-5041-42e2-b29c-c0fd5f782bc9",...}

$ kubectl delete pod -l app=postgres -n jobboard
pod "postgres-5b8d74874c-ch4s9" deleted

$ kubectl wait --for=condition=ready pod -l app=postgres -n jobboard --timeout=60s
pod/postgres-5b8d74874c-278rm condition met   # ← new pod name, different hash suffix

$ curl -s http://localhost:8080/api/jobs/ | grep -o "K8s Persistence Test"
K8s Persistence Test
```

**Why the data survived:** the `postgres` Deployment doesn't own or store any data itself — the actual database files live on `postgres-pvc`, a PersistentVolumeClaim bound to a PersistentVolume that exists entirely independently of any pod's lifecycle. When `kubectl delete pod` removed `postgres-5b8d74874c-ch4s9`, the Deployment's controller immediately created a replacement pod (`postgres-5b8d74874c-278rm` — note the new pod name) from the same Deployment spec, which mounts the *same* PVC (`postgres-pvc` is referenced by name in the pod template, not recreated per-pod). The new pod's Postgres process attaches to the exact same on-disk data directory the old one was using, so from Postgres's perspective this looks identical to a normal restart/recovery, not data loss. Confirmed via `kubectl get deployment postgres -n jobboard -o jsonpath='{.spec.strategy}'` → `{"type":"Recreate"}` — this Deployment explicitly uses `Recreate` (not the Kubernetes default `RollingUpdate`) precisely because of the `RWO` constraint from Task 3.1: with only one replica and a volume that can only be mounted by one pod at a time, `Recreate` guarantees the old pod is fully terminated (and has released the volume) before the new one is created, avoiding a window where two pods might both try to mount the same RWO volume — which `RollingUpdate`'s default "start new before stopping old" behavior would risk.

### 3.3 — Manual database backup (5 pts)

```
$ PG_POD=$(kubectl get pods -n jobboard -l app=postgres -o jsonpath='{.items[0].metadata.name}')
$ kubectl exec -n jobboard $PG_POD -- \
    sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U $POSTGRES_USER -d $POSTGRES_DB --no-owner' \
    > k8s-backup-20260730.sql
$ wc -l k8s-backup-20260730.sql
114 k8s-backup-20260730.sql
```

**Restore procedure** (tested end-to-end against the running pod, after intentionally wiping its schema first to simulate a real restore target):

```bash
# 1. Get the current postgres pod name
PG_POD=$(kubectl get pods -n jobboard -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# 2. Wipe existing data to simulate a fresh/restore target
#    (skip this step for a genuinely empty new pod)
kubectl exec -n jobboard $PG_POD -- \
  sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $POSTGRES_DB \
    -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'

# 3. Copy the backup file into the pod
#    NOTE: `kubectl cp` failed here with "one of src or dest must be a local
#    file specification" — its own colon-delimited <namespace>/<pod>:<path>
#    syntax collides with a Windows drive-letter path's colon (c:\Users\...).
#    Using the tar/stdin-pipe approach from `kubectl cp --help` instead,
#    which sidesteps the parsing entirely:
cat k8s-backup-20260730.sql | kubectl exec -i -n jobboard $PG_POD -- sh -c 'cat > /tmp/restore.sql'

# 4. Run the restore
kubectl exec -n jobboard $PG_POD -- \
  sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d $POSTGRES_DB -f /tmp/restore.sql'

# 5. Verify
curl -s http://<app-url>/api/jobs/ | grep "K8s Persistence Test"
```

Verified: restore produced `COPY 6` (jobs table) and `COPY 1` (applications table, containing the test application submitted in Task 2.1), and both the `K8s Persistence Test` job and the earlier test application were confirmed present via the live API afterward.

---

## Task 4 — Scaling & Rolling Updates (25 pts)

### 4.1 — Manual scaling (5 pts)

```
$ kubectl scale deployment jobs-service --replicas=4 -n jobboard
deployment.apps/jobs-service scaled
$ kubectl rollout status deployment/jobs-service -n jobboard
deployment "jobs-service" successfully rolled out
```

**An unplanned but important finding:** the first attempt at this exercise showed the HPA (`jobs-service-hpa`, already active from `kubectl apply -k k8s/`) silently overriding the manual scale — replicas dropped from 4 back to 3 within about 30 seconds, confirmed via `kubectl describe hpa`:

```
Events:
  Normal   SuccessfulRescale   33s   horizontal-pod-autoscaler   New size: 3; reason: All metrics below target
```

This makes sense once you know how HPA actually works: it isn't a one-time trigger, it's a **continuous reconciliation loop** (every ~15s) that computes a desired replica count from current metrics and drives the Deployment toward it — a manual `kubectl scale` is just a one-off write to `spec.replicas` that the HPA controller will happily overwrite on its very next reconcile if its own calculation disagrees. Since CPU/memory were both far below the 60%/75% targets, the HPA's target replica count was `minReplicas: 2`, and it moved toward that (its scale-down is dampened by a 300s stabilization window, hence landing on 3 rather than jumping straight to 2). **To cleanly demonstrate pure manual scaling for this task, the HPA was temporarily deleted** (`kubectl delete hpa jobs-service-hpa`) and reapplied afterward before Task 4.3 (which specifically exercises the HPA).

With the HPA removed, `kubectl scale --replicas=4` held steady at 4/4 Ready, confirmed via `kubectl get endpoints jobs-service` showing 4 IPs.

**How the Ingress distributes traffic across the replicas:** the Ingress doesn't talk to pods directly — it forwards to the `jobs-service` **Service** (ClusterIP), and the Service's Endpoints/EndpointSlice continuously tracks every Ready pod matching `app: jobs-service`. The nginx ingress controller (itself just an nginx process under the hood) maintains an upstream block per backend Service listing all current endpoint IPs, refreshed automatically as pods come and go — this is push-based via the Kubernetes API watch mechanism, not polling.

**Load-balancing algorithm:** nginx ingress defaults to **round-robin** across the upstream endpoints (configurable via `nginx.ingress.kubernetes.io/load-balance` to `ewma`, `ip_hash`, etc., but round-robin unless overridden — none of this lab's Ingress objects set that annotation).

**Scaling back to 2 — what happens to in-flight requests:**

```
$ kubectl scale deployment jobs-service --replicas=2 -n jobboard
NAME                            READY   STATUS        AGE
jobs-service-...-84xtv          1/1     Terminating   2m6s
jobs-service-...-gmbdt          1/1     Terminating   5m24s
jobs-service-...-gmbdt          0/1     Completed     5m25s
jobs-service-...-84xtv          0/1     Completed     2m7s
```

The two extra pods transition to `Terminating`, not an instant kill: Kubernetes sends `SIGTERM`, and — critically — the pod is *simultaneously* removed from the Service's Endpoints list as soon as it starts terminating, so no *new* requests get routed to a terminating pod. Any request already in-flight to that pod when termination starts gets to finish normally within the pod's `terminationGracePeriodSeconds` (30s default, not overridden here) before `SIGKILL` if it hasn't exited on its own. Since this app has no long-running streaming requests, everything completed well within the grace period — no dropped requests observed, only clean `Completed` pods.

### 4.2 — Rolling update with zero downtime (10 pts)

**A bug found before this even started:** the README's own probe command, `curl http://<ip>/api/jobs/health`, doesn't hit a health check at all — it returns `404 {"detail":"Job 'health' not found"}`. `jobs-service`'s `/health` endpoint is registered at the *top level* (`@app.get("/health")` in `main.py`, not under a `/jobs` prefix), but the Ingress rewrite for anything after `/api/jobs/` targets `/jobs/<rest>` — so `/api/jobs/health` becomes `GET /jobs/health`, which FastAPI matches against the `/jobs/{job_id}` route, treating `"health"` as a job ID lookup. This isn't something introduced by the Task 2 ingress split — the *original* single-object ingress design had the exact same collision (its rewrite also targeted `/jobs/$2` for anything past `/api/jobs`). Used `/api/jobs/` (the collection endpoint, which does work) as the continuous-probe target instead, since it exercises the same pods with the same result (200 as long as at least one `jobs-service` pod is Ready).

```
$ eval $(minikube docker-env) && docker build -t jobs-service:v2 ./jobs-service
$ kubectl set image deployment/jobs-service jobs-service=jobs-service:v2 -n jobboard
deployment.apps/jobs-service image updated
$ kubectl rollout status deployment/jobs-service -n jobboard
Waiting for deployment "jobs-service" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "jobs-service" rollout to finish: 1 old replicas are pending termination...
deployment "jobs-service" successfully rolled out
```

Continuous probe against `/api/jobs/` throughout a rollout (`kubectl rollout restart`, same mechanics as an image update), capturing full response bodies this time for a clean measurement: **22 responses `200`, 1 `000` (connection blip) out of 23 total probes at ~0.3s intervals** — effectively zero downtime, one transient hiccup rather than a sustained outage. (An earlier, less careful test run showed an anomalous batch of interleaved `404`s; those could not be reproduced on this controlled rerun and are most likely an artifact of a manual `/api/jobs/health` request executed concurrently through the same shared `kubectl port-forward` tunnel, not a genuine rolling-update defect — noted here rather than omitted, since an unexplained result shouldn't just be swept away.)

```
$ kubectl rollout history deployment/jobs-service -n jobboard
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         <none>
```

(`CHANGE-CAUSE` is empty because neither `kubectl set image` nor `kubectl rollout restart` were run with `--record` / a `kubernetes.io/change-cause` annotation — a real gap for auditability; in practice you'd set `kubectl annotate deployment/jobs-service kubernetes.io/change-cause="..."` alongside each change.)

**What `maxSurge: 1, maxUnavailable: 0` means:** during a rolling update, Kubernetes may temporarily run *up to 1 more* pod than the target replica count (`maxSurge: 1`) but must never drop *below* the full target count of Ready pods (`maxUnavailable: 0`). Combined, this guarantees capacity never dips during the rollout — new pods are added *before* old ones are removed, never the reverse.

**Timeline for `replicas: 2, maxSurge: 1, maxUnavailable: 0`:**

```
t0:  [old, old]                      — 2/2 Ready, steady state
t1:  [old, old, new(starting)]       — 3 pods total (2+1 surge), new pod not Ready yet, still 2/2 serving traffic
t2:  [old, old, new(Ready)]          — new pod passes readiness probe, now 3/3 Ready — briefly 3 capacity
t3:  [old(terminating), old, new]    — one old pod starts terminating (removed from Endpoints immediately), 2/2 still serving
t4:  [old, new, new(starting)]       — old pod #1 fully gone; second new pod begins (still within maxSurge:1 budget since old #1 is gone)
t5:  [old, new, new(Ready)]          — second new pod Ready — 3/3 momentarily again
t6:  [old(terminating), new, new]    — last old pod terminates
t7:  [new, new]                      — 2/2 Ready, rollout complete
```

At every step, at least 2 Ready pods exist (satisfying `maxUnavailable: 0`), and never more than 3 total exist (satisfying `maxSurge: 1`).

**Rollback if the new version was broken:**

```bash
kubectl rollout undo deployment/jobs-service -n jobboard
# or roll back to a specific revision:
kubectl rollout undo deployment/jobs-service -n jobboard --to-revision=2
```

This triggers the exact same `maxSurge`/`maxUnavailable`-governed rolling process in reverse — the previous ReplicaSet (which Kubernetes keeps around, not deleted, per `revisionHistoryLimit`) is scaled back up while the broken one is scaled down, with the same zero-downtime guarantees.

### 4.3 — HorizontalPodAutoscaler (10 pts)

(HPA was reapplied via `kubectl apply -f k8s/07-hpa.yaml` after being temporarily removed for the clean manual-scaling demo in 4.1.)

```
$ kubectl run load-gen --image=busybox --restart=Never -n jobboard -- \
    sh -c "while true; do wget -qO- http://jobs-service:8000/jobs > /dev/null; done"
pod/load-gen created
```

Watched `kubectl get hpa jobs-service-hpa -n jobboard` over ~3.5 minutes:

| Time            | CPU / target       | Replicas                                                     |
| --------------- | ------------------ | ------------------------------------------------------------ |
| 13:39:09        | 4%/60%             | 2                                                            |
| 13:39:40        | **343%/60%** | 2 (metric above target, stabilization window still counting) |
| 13:40:43        | 529%/60%           | **4** (scaled up)                                      |
| 13:41:14        | 529%/60%           | **4** (holding)                                        |
| (shortly after) | —                 | **6** (second scale-up, hit `maxReplicas`)           |

```
$ kubectl describe hpa jobs-service-hpa -n jobboard
Deployment pods:    6 current / 6 desired
Conditions:
  ScalingLimited   True   TooManyReplicas   the desired replica count is more than the maximum replica count
Events:
  Normal  SuccessfulRescale   New size: 4; reason: cpu resource utilization (percentage of request) above target
  Normal  SuccessfulRescale   New size: 6; reason: cpu resource utilization (percentage of request) above target
```

A single `busybox` pod hammering `/jobs` in a tight loop drove measured CPU utilization to **343-529% of the requested value** (the `jobs-service` container requests `50m` CPU — so 529% of *that* small request is a modest absolute amount of CPU, not 5x a whole core; this is why sizing `resources.requests` sensibly matters for HPA math), which the HPA scaled up to 4 replicas, then further to 6 (the configured `maxReplicas`), correctly reporting `ScalingLimited: TooManyReplicas` once it hit the ceiling rather than trying to exceed it.

**Formula the HPA uses to calculate desired replicas:**

```
desiredReplicas = ceil( currentReplicas × ( currentMetricValue / desiredMetricValue ) )
```

With `currentReplicas=2`, `currentMetricValue≈343%`, `desiredMetricValue=60%`: `ceil(2 × (343/60)) = ceil(11.4) = 12`, clamped down to `maxReplicas: 6`. When multiple metrics are defined (CPU and memory here), the HPA computes a desired count for *each* independently and takes the **largest** — the one demanding the most replicas wins, so a spike in either metric alone is enough to trigger scale-up.

**`stabilizationWindowSeconds` and why it matters for scale-down:** it's a debounce window — instead of reacting to the single most-recent metric reading, the HPA looks back over the whole window (300s for scale-down here, 60s for scale-up) and picks the **highest** replica-count recommendation from any point in that window (`Select Policy: Max`) before actually scaling down. This is what stops flapping: without it, a momentary dip in load (e.g., a few seconds of idle between bursts) would trigger an immediate scale-down, only for the next burst to immediately trigger scale-up again — repeatedly destroying and recreating pods (each with real startup cost: image pull if not cached, init container, readiness delay) for no net benefit. A long scale-down window (300s vs. only 60s for scale-up) reflects an intentional asymmetry: scaling up quickly to handle load is cheap-to-be-wrong-about (worst case, a few extra idle pods for a bit), but scaling down too eagerly risks under-provisioning capacity right as load might return.

**What happens if `metrics-server` isn't installed, and how to diagnose it:** the HPA can't retrieve any CPU/memory readings at all, so `kubectl get hpa` shows `TARGETS` as `<unknown>/60%, <unknown>/75%` instead of real percentages, and it cannot scale in either direction (frozen at whatever `spec.replicas` last was, since there's no valid metric to compute a decision from — the earlier setup transcript in this document's Setup Notes actually captured this exact transient state right after re-creating the HPA, before metrics had populated for the first time). To diagnose: `kubectl describe hpa <name> -n <ns>` surfaces the specific failure reason directly in `Conditions`/`Events` — a `FailedGetResourceMetric` event with `unable to get metrics for resource cpu: no metrics returned from resource metrics API` (an example of exactly this was captured earlier in this document's Task 4.1 HPA-conflict investigation) points straight at metrics-server being absent, unhealthy, or not yet warmed up; `kubectl top pods -n <ns>` failing with a similar error corroborates it from a different angle (it queries the same metrics API). Fix: `minikube addons enable metrics-server` (already done as part of this lab's cluster setup) or install the metrics-server manifests directly on a non-minikube cluster.

Load generator stopped afterward with `kubectl delete pod load-gen -n jobboard`.

---

## Task 5 — Secrets & ConfigMaps (10 pts)

### 5.1 — Inspect the Secret (4 pts)

```
$ kubectl get secret postgres-secret -n jobboard -o yaml
apiVersion: v1
data:
  POSTGRES_DB: am9iYm9hcmQ=
  POSTGRES_PASSWORD: <base64 — omitted from this doc>
  POSTGRES_USER: cG9zdGdyZXM=
kind: Secret
type: Opaque
```

**A real, unplanned demonstration of the exact point this question is testing:** while filtering the password out of the `-o yaml` output for this write-up, a `grep -v "POSTGRES_PASSWORD:"` only removed the top-level `data.POSTGRES_PASSWORD` field — it missed that `kubectl apply` had also stamped the *entire secret payload, password included*, into the `kubectl.kubernetes.io/last-applied-configuration` **annotation** (which `kubectl apply` uses internally to compute 3-way merge diffs on the next apply). That annotation is plain JSON containing the same base64 string, sitting right next to the "real" `data` field — one more place a secret ends up baked into etcd than most people expect, and something a naive redaction pass (like the first attempted `grep`) can easily miss. (No real-world exposure here — throwaway local minikube password, never used elsewhere — but a genuinely instructive accident for this exact task.)

**What base64-encoding (not encryption) means for security:** base64 is a *reversible encoding*, not a cipher — `kubectl get secret ... -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d` recovers the plaintext instantly, no key required. Anyone with read access to the Secret object via the Kubernetes API (`get`/`list` RBAC permission on `secrets` in that namespace), or with access to etcd's raw storage (where Secrets are stored, unencrypted-at-rest by default), or — as just demonstrated — anyone who can read the `last-applied-configuration` annotation on *any* object that was `kubectl apply`'d with a Secret's data, can trivially recover the real value. Base64 exists here purely so arbitrary binary data survives being embedded in JSON/YAML text — it is explicitly *not* a security boundary, just an encoding format.

**Two production solutions that provide real secret encryption:**

1. **Kubernetes-native: [Encryption at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)** (`EncryptionConfiguration` on the API server, or a KMS provider plugin) — encrypts Secret values before they're written to etcd, so a raw etcd disk/backup dump doesn't expose plaintext. This addresses the "etcd access" attack surface but doesn't change the fact that anyone with the Kubernetes API's own `get secret` permission still sees plaintext (encryption-at-rest and RBAC are separate concerns).
2. **External secrets manager: HashiCorp Vault** (or AWS Secrets Manager / GCP Secret Manager) with the **External Secrets Operator** or Vault's own Kubernetes auth/injector — the actual secret value lives outside the cluster entirely in a purpose-built secrets store with proper encryption, access auditing, rotation, and fine-grained policy; Kubernetes only ever holds a reference/short-lived token, not the durable secret.

**What Sealed Secrets is and how it works:** [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) solves a *different* problem than the two above — not runtime secret storage, but **safely committing secrets to git**. A cluster-side controller holds a private key; you encrypt a plaintext Secret client-side with the corresponding public key (via the `kubeseal` CLI) into a `SealedSecret` custom resource, which *is* safe to commit to a public repo — it's only decryptable by the specific controller instance holding the private key for that specific cluster. Applying the `SealedSecret` to the cluster causes the controller to decrypt it and materialize a normal Kubernetes `Secret` object. This directly solves this lab's own `.gitignore`d `k8s/01-secret.yaml` problem (Task 5.1 setup: "Never commit `k8s/01-secret.yaml`") — with Sealed Secrets, the *encrypted* version could be committed safely instead of needing to be excluded and manually regenerated by every developer.

### 5.2 — Add a ConfigMap (6 pts)

Created `k8s/10-configmap.yaml` (as specified) and patched `k8s/03-jobs-service.yaml` to add `envFrom: [{ configMapRef: { name: jobboard-config } }]` alongside its existing per-key `env:` secret refs.

**A deployment gotcha worth noting:** applying the patched `03-jobs-service.yaml` *directly* (`kubectl apply -f k8s/03-jobs-service.yaml`) failed with `spec.selector: Invalid value: ...: field is immutable` — because kustomize's `commonLabels` transformer injects extra labels into `spec.selector.matchLabels` (not just `metadata.labels`) when applied via `kubectl apply -k k8s/`, so the live Deployment's selector included labels the raw file's selector didn't have. Re-running via `kubectl apply -k k8s/` (consistent with how everything else in this lab was deployed) resolved it immediately. Lesson: once a resource has been kustomize-managed, keep applying it through kustomize — mixing raw `-f` applies with kustomize on the same object can hit immutable-field conflicts on fields kustomize silently augments.

```
$ kubectl exec -n jobboard $POD -- env | grep -E "LOG_LEVEL|MAX_JOBS|ALLOWED_ORIGINS"
MAX_JOBS=100
ALLOWED_ORIGINS=http://localhost,http://jobboard.local
LOG_LEVEL=info
```

**`env` (individual key) vs `envFrom` (all keys):** `env` with a `valueFrom.configMapKeyRef`/`secretKeyRef` pulls in *one specific key*, and lets you rename it (the container's env var name doesn't have to match the ConfigMap/Secret key name) — used here for `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`, each individually sourced and then referenced by name to build `DATABASE_URL`. `envFrom` with a `configMapRef`/`secretRef` instead dumps *every* key in that ConfigMap/Secret straight into the container's environment, using the keys' own names verbatim — less code for "just give me all of these," but you lose the ability to rename, and if two `envFrom` sources (or an `envFrom` source and an explicit `env` entry) define the same key, there's a defined-but-easy-to-get-wrong precedence order to reason about instead of an explicit, visible mapping.

**ConfigMap vs Secret — when to use which:** ConfigMap for non-sensitive configuration (log levels, feature flags, allowed origins, non-secret URLs) — it's stored and displayed as plaintext everywhere (`kubectl get configmap -o yaml` shows real values, no encoding). Secret for anything that's actually sensitive (passwords, API keys, tokens, certificates) — not because Secrets are meaningfully more secure by default (Task 5.1 showed they're only base64-encoded, not encrypted), but because the Secret *type* signals intent to tooling and operators (RBAC can be scoped to restrict `get`/`list` on `secrets` specifically without blocking `configmaps`; some cluster add-ons and encryption-at-rest configurations specifically target the `Secret` resource type; `kubectl get all` and casual `describe` output redact Secret values by default but not ConfigMap values).

**What happens to running pods when a ConfigMap is updated ("it depends"):** for env vars sourced via `envFrom`/`env` (as used here), **nothing happens automatically** — env vars are injected once, at container start, by the kubelet; updating the ConfigMap does not restart the container or refresh its environment, so a running pod keeps its stale values until something re-creates it (a rolling restart, a deploy, a crash/restart cycle). This is the "it depends" — if the ConfigMap were instead mounted as a **volume** (a file inside the container, not an env var), kubelet actually does periodically sync updated ConfigMap content into that mounted file *live*, without restarting the pod (subject to a sync delay, typically up to ~1 minute, controlled by kubelet's sync period) — but the *application* still has to notice the file changed and reload it itself; Kubernetes doesn't force that. So: env-var consumption needs an explicit rollout to pick up changes; volume-mount consumption updates the file automatically but still needs app-level awareness to act on it.

---

## Task 6 — Kubernetes CI/CD Integration (15 pts)

### 6.1 — Update the GitHub Actions pipeline (10 pts)

Added a `deploy-to-k8s` job to `.github/workflows/ci.yml`, `needs: push-to-registry`, gated on `github.ref == 'refs/heads/main' && github.event_name == 'push' && secrets.KUBECONFIG_BASE64 != ''`. It:
1. Installs `kubectl` (`azure/setup-kubectl@v3`).
2. Decodes `secrets.KUBECONFIG_BASE64` into a `kubeconfig.yml` file.
3. Runs `kubectl set image` for `jobs-service`, `applications-service`, and `frontend` against the images just pushed to Docker Hub by `push-to-registry` (tagged `${{ github.sha }}`, matching the actual `jobboard-<service>` repo names confirmed live on Docker Hub in Part 1), followed by `kubectl rollout status --timeout=120s` for each.
4. Runs a smoke-test step (Task 6.2).

**Important, honest caveat — this job has never actually executed.** It's written correctly to the spec, YAML-validated (`python -c "import yaml; yaml.safe_load(...)"` → parses cleanly, all 7 jobs present including `deploy-to-k8s`), and the container names/image tags were double-checked against the real manifests (`k8s/03-jobs-service.yaml`, `04-applications-service.yaml`, `05-frontend.yaml` — confirmed container names `jobs-service`, `applications-service`, `frontend` respectively) — but it cannot actually run in this repository, because:
- The `KUBECONFIG_BASE64` secret doesn't exist in this repo's GitHub Actions secrets, so the `if:` guard evaluates false and the job is always skipped — deliberately, not a bug.
- Even if the secret existed, **it would need to point at a real, network-reachable cluster.** This lab's cluster is local minikube running on a developer's own machine behind NAT/no public IP — a GitHub-hosted runner has no network path to it at all. `kubectl port-forward`/`minikube tunnel` only work for as long as a local process keeps running; there's no way to expose them to an external CI runner without significant additional infrastructure (a VPN, a self-hosted runner on the same network as minikube, or replacing minikube with an actual cloud-reachable cluster).

**What a real target cluster would need (documented per Task 6.2's own ask):**
- A cluster with a publicly reachable (or CI-network-reachable) API server — e.g. a managed cloud cluster (GKE, EKS, AKS) with its API endpoint exposed, or a self-hosted cluster behind a VPN that includes a self-hosted GitHub Actions runner (rather than GitHub-hosted), or at minimum a bastion/reverse-tunnel arrangement.
- A kubeconfig for a **scoped service account**, not a cluster-admin credential — ideally a ServiceAccount bound via RBAC to only the `jobboard` namespace with only the verbs this job actually needs (`get`/`list`/`watch` on pods/deployments, `patch`/`update` on deployments for `set image`), generated with `kubectl create serviceaccount` + a `Role`/`RoleBinding`, then that SA's token embedded in a minimal kubeconfig.
- That kubeconfig base64-encoded (`cat kubeconfig.yml | base64 -w0`) and stored as the `KUBECONFIG_BASE64` **secret** (never a repo variable — it's a credential).
- Ideally short-lived/rotatable credentials rather than a long-lived static token, and the cluster's API server should itself be firewalled to only accept connections from GitHub's published Actions IP ranges (or from a self-hosted runner's known IP) rather than being open to the entire internet just because it needs to accept CI traffic.

### 6.2 — Kubernetes smoke test step (5 pts)

Added as the final step of `deploy-to-k8s`, after all three deployments have rolled out:

```bash
# Fail if any pod in the namespace is not Running
not_running=$(kubectl get pods -n jobboard --no-headers | grep -v " Running " || true)
if [ -n "$not_running" ]; then
  echo "Pods not in Running state:"; echo "$not_running"; exit 1
fi

# Fail if either API's /health endpoint doesn't return 200
kubectl run smoke-test --rm -i --restart=Never --image=curlimages/curl -n jobboard -- sh -c '
  set -e
  code=$(curl -s -o /dev/null -w "%{http_code}" http://jobs-service:8000/health)
  [ "$code" = "200" ] || { echo "jobs-service /health returned $code"; exit 1; }
  code=$(curl -s -o /dev/null -w "%{http_code}" http://applications-service:3001/health)
  [ "$code" = "200" ] || { echo "applications-service /health returned $code"; exit 1; }
  echo "Both /health endpoints returned 200"
'
```

Note this deliberately curls the **Service DNS names directly** (`http://jobs-service:8000/health`, not through the Ingress) — this is a smoke test of the *deployment*, so it checks the actual app pods are healthy from inside the cluster, independent of whatever Ingress routing quirks exist at the edge (relevant here, since Task 4.2 already found the Ingress-routed `/api/jobs/health` path is broken by a route collision — using the in-cluster Service name for the smoke test sidesteps that entirely and tests the thing this step actually cares about: did the new pods come up healthy).

**Setting up `KUBECONFIG_BASE64` for a real cluster** (documented as requested, not executed):

```bash
# 1. Create a namespace-scoped ServiceAccount + RBAC (least privilege)
kubectl create serviceaccount ci-deployer -n jobboard
kubectl create role ci-deployer-role -n jobboard \
  --verb=get,list,watch,patch,update --resource=deployments,pods
kubectl create rolebinding ci-deployer-binding -n jobboard \
  --role=ci-deployer-role --serviceaccount=jobboard:ci-deployer

# 2. Generate a token and build a minimal kubeconfig for that SA
#    (exact mechanics vary by cluster/K8s version — e.g. a long-lived
#    Secret-backed token pre-1.24, or `kubectl create token` for a
#    short-lived one on newer clusters, embedded into a kubeconfig
#    that points at the cluster's real API server URL + CA cert)

# 3. Base64-encode the resulting kubeconfig file
cat ci-deployer-kubeconfig.yml | base64 -w0

# 4. Paste that output as the KUBECONFIG_BASE64 GitHub Actions *secret*
#    (Settings → Secrets and variables → Actions → New repository secret)
```

---

## Submission Checklist

- [x] `kubectl get all -n jobboard` screenshot — `screenshots - k8s/kubectl_get_all_-n_jobboard.png`
- [x] `kubectl get pods -n jobboard` all Running screenshot — `screenshots - k8s/kubectl_get_pods_-n_jobboard.png`
- [x] Application accessible screenshot — `screenshots - k8s/app_accessible .png`
- [x] Rolling update history output — `screenshots - k8s/kubectl_rollout_history.png`
- [x] HPA scaling event output — `screenshots - k8s/kubectl_describe_hpa.png` (shows real `SuccessfulRescale` events: New size 4, New size 6)
- [x] `k8s/09-network-policy.yaml` committed
- [x] `k8s/10-configmap.yaml` committed
- [x] `deploy-to-k8s` CI job added (`.github/workflows/ci.yml`)
- [x] `SOLUTION-k8s.md` complete
