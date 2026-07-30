# SOLUTION.md — DevSecOps Lab: Containerised Job Board Platform

> Filled in progressively as each task is completed. See README.md for the original task prompts.

---

## Setup Issues Found & Fixed (pre-Task 1)

Before any lab task could be attempted, the stack failed to build/start. Root causes and fixes:

1. **Missing `package-lock.json`** in `applications-service/` and `frontend/` — both Dockerfiles use `npm ci`, which requires an existing lockfile (that's the point of `ci`: exact, reproducible installs, unlike `npm install`). Fixed by running `npm install --package-lock-only` in each and committing the generated lockfiles.
2. **URL-unsafe character in `POSTGRES_PASSWORD`** — `docker-compose.yml` builds `DATABASE_URL` via string interpolation: `postgresql://user:${POSTGRES_PASSWORD}@postgres:5432/db`. A password containing `@`, `/`, `#`, `:`, etc. breaks URL parsing in both the Python (`sqlalchemy`) and Node (`pg-connection-string`) clients. Fixed by choosing a strong password using only URL-safe characters.
3. **Stale Postgres data volume** — Postgres sets the superuser password only on first initialization of its data directory. An early failed run had already initialized the volume under the old/default password, so updating `.env` afterward had no effect until the volume was removed (`docker compose down -v`) and reinitialized. Safe here since no real data existed yet.
4. **nginx ↔ FastAPI trailing-slash mismatch** — nginx rewrote `/api/jobs/` → `/jobs/`, but the FastAPI route is defined as `/jobs` (no trailing slash). FastAPI's automatic redirect-slashes behavior issued a `307` to `/jobs` using only the `Host` header (no path prefix), which nginx's catch-all `location /` then routed to the frontend instead of the API. Fixed the nginx rewrite rules in `nginx/nginx.conf` to always produce paths matching FastAPI's actual routes (no trailing slash on the collection endpoint).

---

## Task 1 — Dockerfile Analysis & Hardening (20 pts)

### 1.1 – Vulnerability scan results (8 pts)

Scanned with `trivy image --severity CRITICAL,HIGH` (run via `aquasec/trivy` container against the Docker daemon, since no local Trivy binary was installed):

| Image                   | Base                | CRITICAL | HIGH | Total |
| ------------------------ | -------------------- | -------- | ---- | ----- |
| `jobs-service`            | `python:3.12-slim` (Debian 13.6) | 4        | 19   | 23    |
| `applications-service`    | `node:20-alpine` (Alpine 3.23.4) | 1        | 15   | 16    |
| `frontend`                | `nginx` on Alpine 3.21.3          | 0        | 0    | 0     |

- **Total CRITICAL CVEs across all images: 5** (4 in jobs-service, 1 in applications-service).
- **Image with the most vulnerabilities: `jobs-service`** (23 total, 4 CRITICAL) — it's Debian-slim based, which ships a larger OS package set (perl, util-linux, ncurses, etc.) than the Alpine-based services, and each of those packages is a potential CVE surface even though the app itself never invokes them.
- `frontend` is clean: the final stage is a plain `nginx` image serving pre-built static assets — no Node.js runtime or `node_modules` ships in the final image, so there's no JS dependency tree to scan.

**CRITICAL CVE deep-dive: `CVE-2026-59873` (tar / node-tar) in `applications-service`**

- **(a) What it is:** A Denial-of-Service vulnerability in the `tar` npm package (used internally by npm/tooling, pulled in transitively) where a maliciously crafted gzip-compressed tar archive ("gzip bomb") can cause excessive memory/CPU consumption during extraction, potentially crashing or hanging the process that unpacks it.
- **(b) Package affected:** `tar@6.2.1`, a transitive dependency (not declared directly in `package.json` — pulled in by npm's own tooling / lockfile resolution). Fixed in `tar@7.5.19`.
- **(c) Fix / mitigation:** Because this is transitive, `npm audit fix` (or `npm audit fix --force` if it requires a major bump) resolves it by adding an `overrides` entry pinning `tar` to a patched version. Since this package is never actually used to extract untrusted archives at runtime by our own application code, the practical risk to `applications-service` is low — but it should still be patched because it ships in the image and widens the attack surface unnecessarily. This is a good example of why **dependency pinning + `npm audit` in CI** (Task 4) matters: it catches exactly this class of issue automatically on every build rather than requiring a manual Trivy pass.

Full raw scan output available by re-running:
```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest image --severity CRITICAL,HIGH lab-job-board-jobs-service:latest
```

### 1.2 – Dockerfile hardening changes (12 pts)

- [x] Non-root user verified — `docker run --rm <image> whoami` returns `appuser` for both `jobs-service` and `applications-service`.
- [x] `FROM` pinned to exact digest in both stages of `jobs-service/Dockerfile` (`python:3.12-slim@sha256:57cd7c3a...`) and `applications-service/Dockerfile` (`node:20-alpine@sha256:fb4cd12c...`). Pinning by digest (not just tag) guarantees the exact same image bytes are pulled on every build — a `:tag` can be repointed by the registry at any time (accidentally or via supply-chain compromise), silently changing what ships to production.
- [x] `.dockerignore` verified complete for both services (excludes `.git`, `.env`, docs, caches; `jobs-service` also correctly excludes `tests/` so test code never ships in the runtime image).
- [x] `HEALTHCHECK` verified — and a real bug found in the process: `frontend/Dockerfile` and `nginx/Dockerfile` healthchecks used `wget http://localhost:80`, but `localhost` resolves to `::1` (IPv6) first inside the Alpine container while nginx only binds `0.0.0.0` (IPv4-only), so every healthcheck failed with "connection refused" even though the app was working fine and reachable from outside. Fixed by pointing both healthchecks at `127.0.0.1` explicitly. All 5 containers now report `healthy` in `docker compose ps`.
- [x] Layer count reduced in `applications-service/Dockerfile`: `apk update/upgrade`, user creation, and `chown` are now chained into a single `RUN` with `&&`, and moved after the `COPY` steps so the ownership fix happens in one pass instead of being its own layer.

**Before/after image sizes:**

| Image                   | Size    | Notes                                                        |
| ------------------------ | ------- | ------------------------------------------------------------- |
| `jobs-service`            | 274MB   | Unchanged — digest pinning and layer chaining don't remove installed content, they improve reproducibility and shave one layer. |
| `applications-service`    | 223MB   | Unchanged for the same reason.                                |
| `frontend`                | 98MB    | Unchanged (healthcheck-only fix).                              |
| `nginx`                   | 97.7MB  | Unchanged (healthcheck-only fix).                              |

Note: meaningful size reduction (e.g. switching `jobs-service` from `python:3.12-slim` to a smaller base, or trimming unused Debian packages) was out of scope for this pass since it risks breaking `psycopg2`'s native dependencies — flagged as a follow-up, not attempted here to avoid an unverified change.

---

## Task 2 — Docker Compose Orchestration (25 pts)

### 2.1 – Logging configuration (8 pts)

Added a shared `x-logging` YAML anchor at the top of `docker-compose.yml`:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

and referenced it as `logging: *default-logging` on every service (`postgres`, `jobs-service`, `applications-service`, `frontend`, `nginx`). Using a YAML anchor instead of pasting the same 5-line block 5 times means the retention policy is defined once — if it needs to change, it changes in one place. Verified with `docker inspect jobs-service --format='{{json .HostConfig.LogConfig}}'` → `{"Type":"json-file","Config":{"max-file":"3","max-size":"10m"}}`, and `docker compose logs -f jobs-service` streams correctly.

### 2.2 – Environment variable isolation (9 pts)

Changes made:

1. `.env` created from `.env.example` with a strong `POSTGRES_PASSWORD` (16+ chars, mixed case, digits — URL-safe characters only, since the password gets interpolated into a `postgresql://` connection string; see the Setup Issues section above for why that constraint matters).
2. Removed the insecure default fallback. Previously `docker-compose.yml` had `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-jobboard123}` on `postgres`, `jobs-service`, and `applications-service` — meaning the stack would silently start with a well-known, hardcoded weak password if `.env` was ever missing. Changed to `${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in .env}`, Compose's "required variable" syntax: this fails the build/start with a clear error instead of failing open into an insecure default.
3. Verified: renamed `.env` away and ran `docker compose config` → got `error while interpolating services.postgres.environment.POSTGRES_PASSWORD: required variable POSTGRES_PASSWORD is missing a value: POSTGRES_PASSWORD must be set in .env`. Restored `.env` → `docker compose config` succeeds again.
4. `.env` is already listed in `.gitignore` (confirmed present at repo root). No `git status` output to show yet since this working copy hasn't been initialized as a git repository (Task 4.1 covers pushing to GitHub).

**Why committing `.env` to git is a security risk:** a `.env` file holds live credentials (database password here, potentially API keys/tokens elsewhere). Once committed, it's in the repository's history permanently — even deleting the file in a later commit doesn't remove it from history, so anyone with clone access (or anyone who ever forks/mirrors the repo, including automated scrapers that specifically hunt GitHub for leaked `.env` files) can extract the secret. If the repo is or ever becomes public, or if access control on a "private" repo is ever misconfigured, the credential is compromised instantly and the fix requires rotating the secret everywhere it's used, not just removing the file.

**Tooling that helps prevent this:**
- **`git-secrets`** — a pre-commit hook that scans staged changes for patterns matching common credential formats (AWS keys, etc.) and blocks the commit.
- **`truffleHog`** — scans full git history (not just the current diff) for high-entropy strings and known secret patterns; useful for auditing a repo after the fact, not just preventing new leaks.
- **GitHub secret scanning** (built into GitHub, free for public repos, available via GitHub Advanced Security for private repos) — scans pushed commits against known secret-provider signatures and can automatically notify/revoke for supported providers (e.g., AWS, Stripe).
- **`.gitignore` + `.env.example`** (already in place here) — the cheapest and most important layer: never let the secret-bearing file enter the staging area in the first place. Tooling like the above is defense-in-depth for when this discipline slips.

### 2.3 – Restart policy & dependency ordering (8 pts)

**Dependency graph:**

```
postgres (healthcheck: pg_isready)
   │  condition: service_healthy
   ├──────────────┬───────────────────┐
   ▼              ▼                   
jobs-service   applications-service
   │              │
   │  condition: service_healthy (both)
   └──────┬───────┘
          ▼
       frontend
          │  condition: service_healthy
          ▼
        nginx  (also depends_on jobs-service, applications-service — service_healthy)
```

Observed real startup order from `docker compose up` logs: `jobboard-db Healthy` → `jobs-service`/`applications-service` start together, then both report `Healthy` → `jobboard-frontend` starts and reports `Healthy` → `nginx-proxy` starts. This matches the graph.

**`condition: service_healthy` vs `condition: service_started`:**
- `service_started` (the default when no `condition` is given, e.g. a plain `depends_on: [frontend]` list) only waits for the container process to *start* — it says nothing about whether the app inside is actually ready to accept traffic. A dependent service could start immediately after and hit connection-refused errors during the app's warm-up window.
- `service_healthy` waits for the dependency's `HEALTHCHECK` to report `healthy`, which actually verifies the app is accepting requests (e.g. `pg_isready`, an HTTP `/health` probe). This is why `postgres` needing `service_healthy` (not just `service_started`) matters: Postgres's process starts almost instantly, but it isn't ready to accept connections until its initialization/recovery finishes.
- Fixed as part of this task: `nginx`'s `depends_on` originally used the bare list form (`- frontend` / `- jobs-service` / `- applications-service`), which is `service_started` only, even though all three of those services define healthchecks. Changed nginx to use explicit `condition: service_healthy` for all three, so nginx doesn't start proxying before its upstreams are actually ready.

**What happens if postgres crashes after the other services are running?** (`docker compose stop postgres`)

`depends_on` conditions are only evaluated at startup — they gate the *order in which containers are created*, not ongoing runtime supervision. So stopping `postgres` after `jobs-service`/`applications-service` are already running does **not** stop them; they keep running and will simply start failing individual database queries (surfaced as 500s / connection errors on API calls) until `postgres` comes back. `postgres` itself has `restart: unless-stopped`, so if the container crashed (rather than being deliberately stopped) Docker would restart it automatically; a manual `docker compose stop postgres` is respected and it stays down until `docker compose start postgres` is run. This is a real gap for production use — `depends_on` + healthchecks solve the *startup ordering* problem but not the *runtime resilience* problem; that requires the application layer to retry/backoff on DB connection loss (both services here use connection pools, which will retry new connections once postgres returns, but in-flight requests during the outage will fail).

---

## Task 3 — Data Persistence & Backup (15 pts)

### 3.1 – Persistence across restarts (5 pts)

Created a job via the API (`POST /api/jobs/` → `"Persistence Test Job"`, id `fa0bdf6e-0759-4360-88fa-e5163af7bf87`), ran `docker compose stop` then `docker compose start` (not `down -v`), and confirmed via `GET /api/jobs/` that the job still exists afterward. This works because `stop`/`start` only stop and restart the *containers* — the named volume (`postgres-data`) backing Postgres's data directory is never touched, so the database's on-disk files persist across the container lifecycle.

### 3.2 – Volume inspection (4 pts)

`docker volume inspect jobboard-postgres-data` reports:
```
"Mountpoint": "/var/lib/docker/volumes/jobboard-postgres-data/_data"
```

- **Where the data actually lives:** On Linux hosts this path is directly on the host filesystem. On Windows with Docker Desktop (this environment), Docker Engine actually runs inside a lightweight VM (WSL2 backend), so that path is inside the VM's filesystem, not directly browsable from Windows Explorer — it's reachable only via `docker exec`/`docker cp` or by inspecting the WSL2 distro's disk directly. This is an important practical distinction: "it's on the host" is only literally true on native Linux Docker hosts.
- **Named volume vs bind mount:** A named volume (`postgres-data:/var/lib/postgresql/data`, used here) is fully managed by Docker — Docker decides where it lives on disk, handles permissions, and it survives `docker compose down` (without `-v`) independent of the project directory. A bind mount (`./data:/var/lib/postgresql/data`) instead maps a specific host directory directly into the container — the host path is fixed, human-browsable, and exists whether or not any container is using it, but permission/ownership mismatches between host and container UARE more error-prone, and behavior isn't portable across OSes (a Windows host path handled differently than a Linux one).
- **When to prefer each in production:** Named volumes are generally preferred for database data — you don't need direct host access to individual data files, Docker manages the backing storage (and this is also what allows volume drivers to plug in networked/cloud storage transparently). Bind mounts are preferred when you need direct host visibility/editing of the files — e.g. mounting source code for live-reload in development, or mounting a host-managed config/secrets directory that's provisioned by something outside Docker (like a config-management tool).

### 3.3 – Backup and restore (6 pts)

Backup taken with the README's exact command:
```bash
docker exec jobboard-db pg_dump -U postgres -d jobboard --no-owner --no-acl -F plain > backup_20260730_071900.sql
```

**Note on the verification command:** the README suggests `grep -c "INSERT INTO" backup_*.sql` to verify the dump — but `pg_dump`'s plain-format default emits data via `COPY ... FROM stdin` blocks, not individual `INSERT` statements (COPY is Postgres's native bulk-load format and is far more efficient for large tables). So that grep will correctly report `0` even for a valid, complete backup. The actually-correct verification is:
```bash
grep -c "^COPY" backup_*.sql        # → 2 (one per table: jobs, applications)
grep -A2 "^COPY public.jobs" backup_*.sql   # inspect the row data directly
```
(`pg_dump --inserts` would force `INSERT`-statement output if that format is specifically wanted — at a real cost of import speed on restore.)

**Restore procedure** (tested end-to-end against a fresh container/volume):

```bash
# 1. Start only postgres (fresh volume in this test — docker compose down -v was run first)
docker compose up -d postgres

# 2. IMPORTANT: postgres auto-runs init-db/init.sql on first boot of a fresh volume,
#    which seeds 5 demo jobs. Restoring the dump on top of that causes primary-key
#    conflicts (CREATE TABLE already exists, duplicate rows). Drop and recreate the
#    schema first so the dump lands on a genuinely empty target:
docker exec jobboard-db psql -U postgres -d jobboard -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# 3. Copy the backup file into the container
docker cp backup_20260730_071900.sql jobboard-db:/tmp/backup.sql

# 4. Run the restore
docker exec jobboard-db psql -U postgres -d jobboard -f /tmp/backup.sql

# 5. Verify
docker exec jobboard-db psql -U postgres -d jobboard -c "SELECT title FROM jobs ORDER BY created_at;"

# 6. Bring the rest of the stack up
docker compose up -d
```

Verified restore produced all 6 rows (5 original seed jobs + the persistence-test job), confirming the backup/restore round-trip is correct.

---

## Task 4 — CI/CD Pipeline with GitHub Actions (25 pts)

### 4.2 – Pipeline verification (10 pts)

`.github/workflows/ci.yml` implements all 6 required stages:

| Stage | What it does |
| --- | --- |
| `lint-test-python` | Installs `jobs-service/requirements-dev.txt`, runs `ruff check` (linting), then `pytest tests/` (unit tests, SQLite-backed, no live DB). |
| `lint-test-node` | Matrix job over `applications-service` and `frontend`: `npm ci` then `npm audit --omit=dev --audit-level=high`. |
| `build-images` | `docker compose build` for all 4 services; saves each image as a `.tar` artifact for downstream jobs (avoids rebuilding in every job). |
| `scan-images` | Loads the built images and runs `aquasecurity/trivy-action` against each of the 4, `exit-code: "0"` (report-only, doesn't fail the build — see rationale below) with reports uploaded as artifacts. |
| `integration-test` | Loads the built images, writes a CI-only `.env`, brings up the full stack with `docker compose up -d`, polls `docker compose ps --format json` until no service reports `starting`/`unhealthy`, then runs real `curl` assertions against `/api/jobs/`, `/api/applications/`, `/`, and a `POST /api/jobs/` round-trip. Always tears down with `docker compose down -v` regardless of outcome. |
| `push-to-registry` | Only runs `if: github.ref == 'refs/heads/main' && github.event_name == 'push'`; logs into Docker Hub with `secrets.DOCKERHUB_USERNAME`/`secrets.DOCKERHUB_TOKEN`, tags each image with both `:latest` and `:<git-sha>`, pushes all 4. |

**Design decisions worth calling out:**
- `scan-images` uses `exit-code: "0"` rather than failing the build on any CRITICAL finding. Given Task 1.1's scan found 5 CRITICAL CVEs already present in upstream base images (Debian/Alpine OS packages, not our own code) with no available fix version at time of scanning, a hard-fail gate would permanently block every build. **Labeled as an acceptable risk, not best practice**: the correct production posture is `exit-code: "1"` with an explicit `.trivyignore` for CVEs that are reviewed-and-accepted (with an expiry date), not a blanket pass-through. Documented here rather than silently chosen.
- All 4 images are built once in `build-images` and passed as artifacts to `scan-images`/`integration-test`/`push-to-registry`, rather than each job rebuilding — faster CI and guarantees every downstream job scans/tests/pushes the exact same image bytes.
- The `integration-test` job's health-poll loop was validated against this local stack: `docker compose ps --format json` emits one JSON object per line with a `"Health"` field, confirmed by direct inspection, so the `grep -c '"Health":"unhealthy"'` line-counting approach is accurate (not assumed).
- Local validation performed for everything that doesn't require an actual GitHub Actions runner: `ruff check` passes cleanly on `jobs-service/app` and `tests/`; `pytest tests/` passes 4/4 inside the built `jobs-service` image; `npm audit --omit=dev --audit-level=high` passes clean for both `applications-service` and `frontend` (the moderate/high findings visible in an unrestricted `npm audit` are exclusively in `devDependencies` — Vite's dev-server tooling for `frontend`, never shipped to the production image, confirmed by frontend's Trivy scan showing 0 vulnerabilities; and a `uuid` bounds-check advisory in `applications-service` that only affects `v3/v5/v6` calls with an explicit `buf` argument, which this codebase never does — see accepted-risk note below); and all `integration-test` `curl` assertions were run manually against the live local stack and pass.
- **Pipeline verified green end-to-end**: repository pushed to [github.com/mendilirmak/lab-job-board](https://github.com/mendilirmak/lab-job-board), `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets configured, and all 6 stages pass on `main`: [successful run](https://github.com/mendilirmak/lab-job-board/actions/runs/30526394929). Several real CI-only bugs were found and fixed while getting a fully green run (not from local validation, since GitHub's runner environment differs from the local Docker-image test I ran):
  - `pytest tests/ -v` (bare CLI invocation) doesn't add the working directory to `sys.path` the way `python -m pytest` does — so `from app.main import app` raised `ModuleNotFoundError` in CI even though the exact same test passed locally when invoked via `python -m pytest`. Fixed by adding `jobs-service/pytest.ini` with `pythonpath = .`.
  - `aquasecurity/trivy-action@0.24.0` (the version guessed at write-time) doesn't exist, and the corrected `0.36.0` also failed — the actual git tag needs the `v` prefix (`v0.36.0`). Fixed by checking `gh api repos/aquasecurity/trivy-action/tags` for real tag names instead of guessing.
  - Additionally, Task 6.1's move to Docker secrets meant `docker-compose.yml` no longer reads `POSTGRES_PASSWORD` from `.env` at all (it reads `/run/secrets/db_password`), so the `integration-test` job's env-file-writing step had to be updated to create `secrets/db_password.txt` instead — a compose-file dependency that only surfaced once the pipeline actually ran end-to-end.
  - Docker Hub push failed once with `unauthorized: incorrect username or password` despite the secrets appearing correctly named (`gh secret list` confirmed exact names) — resolved by regenerating the Docker Hub access token with Read & Write scope and re-pasting it directly into the GitHub secret (a copy-paste/scope issue on the credential itself, not the pipeline). Confirmed via job logs: all 4 images (`jobboard-jobs-service`, `jobboard-applications-service`, `jobboard-frontend`, `jobboard-nginx`) pushed with valid digests, tagged both `:latest` and `:<git-sha>`.

**Accepted risk — `uuid@9.0.1` moderate CVE in `applications-service`:**
- **Constraint:** the fix (`uuid@14.0.1`) is a major version bump flagged by npm as breaking.
- **Risk:** `GHSA-w5hq-g745-h8pq` is a missing bounds check when a caller passes a custom `buf` argument to `uuid`'s `v3`/`v5`/`v6` functions.
- **Compensating control:** `applications-service` only calls `uuidv4()` with no arguments (`src/routes/applications.js:71`) — the vulnerable code path (custom `buf`, and non-v4 functions) is never reached by this codebase. Risk is effectively contained by usage pattern, not a code fix. Flagged in the CI dependency audit as `--audit-level=high` (so it doesn't block builds) rather than suppressed entirely — it remains visible in `npm audit` output for anyone re-auditing.

### 4.3 – Unit tests (12 pts)

Added `jobs-service/tests/test_main.py` (4 tests, all passing):

```python
def test_health(): ...                              # GET /health → 200, status "healthy"
def test_create_job_valid_data_returns_201(): ...    # POST /jobs valid → 201
def test_create_job_missing_fields_returns_422(): ...# POST /jobs incomplete → 422
def test_get_job_nonexistent_id_returns_404(): ...   # GET /jobs/{bad-id} → 404
```

**How the database is mocked:** rather than mocking with `unittest.mock`, the test file sets `DATABASE_URL` to a temporary SQLite file *before* importing `app.main` (`database.py` reads `DATABASE_URL` at import time to build its SQLAlchemy engine, so this redirects the app's real `get_db` dependency to SQLite with zero source-code changes or `dependency_overrides` plumbing). An autouse `clean_db` fixture drops/recreates all tables between tests for isolation. This satisfies the task's "mock the database... tests must run in CI without a real database" requirement while keeping the test file the only thing that needs to know about the substitution.

Test dependencies (`pytest`, `httpx` — required by FastAPI's `TestClient` under Starlette ≥0.36 — and `ruff`) live in a new `jobs-service/requirements-dev.txt` that layers on top of `requirements.txt`, kept separate from it and excluded from the Docker build context via the existing `.dockerignore` (`tests/`) so the production runtime image doesn't gain test-only dependencies or CVE surface.

Verified locally by running `pytest` inside the actual built `jobs-service` Docker image (Python 3.12, same environment CI will use):
```
tests/test_main.py::test_health PASSED
tests/test_main.py::test_create_job_valid_data_returns_201 PASSED
tests/test_main.py::test_create_job_missing_fields_returns_422 PASSED
tests/test_main.py::test_get_job_nonexistent_id_returns_404 PASSED
4 passed in 1.24s
```

---

## Task 5 — Networking & Service Communication (10 pts)

### 5.1 – Docker network (4 pts)

`docker network inspect jobboard-network` — bridge network, subnet `172.19.0.0/16`:

| Container | Service | IPv4 Address |
| --- | --- | --- |
| `jobboard-db` | postgres | 172.19.0.2 |
| `applications-service` | applications-service | 172.19.0.3 |
| `jobs-service` | jobs-service | 172.19.0.4 |
| `jobboard-frontend` | frontend | 172.19.0.5 |
| `nginx-proxy` | nginx | 172.19.0.6 |

**How `jobs-service` resolves the hostname `postgres`:** Docker's embedded DNS server (at `127.0.0.11` inside every container on a user-defined bridge network like `jobboard-network`) automatically registers each container's *service name* (from `docker-compose.yml`) as a DNS entry pointing at that container's IP on the network. `jobs-service` never needs to know `postgres`'s IP (172.19.0.2) — its `DATABASE_URL` just says `@postgres:5432/...`, and the container's resolver forwards that lookup to `127.0.0.11`, which returns `172.19.0.2`. Verified directly: connecting to `postgres:5432` from inside `jobs-service` resolved and reached the right container (172.19.0.2 in the error message) — connection failed only on auth (deliberately, using a placeholder password to avoid touching the real one in a command), confirming DNS + routing work correctly and only credentials were the blocker in that test.

**What happens if you try to reach `jobs-service:8000` directly from a browser? Why?** It fails to connect (confirmed: `curl --max-time 3 http://localhost:8000/health` → connection timeout, exit code 7 / no response). This is because `docker-compose.yml` never publishes a `ports:` mapping for `jobs-service` (or `applications-service`, or `frontend`) — only `nginx` has `ports: ["${NGINX_PORT:-80}:80"]`. A container's network is only reachable from the host machine (or the outside world) through an explicit host-port mapping; without one, the container's ports exist only inside the Docker bridge network, reachable by other containers on that same network (like `nginx-proxy`) but invisible from outside it. This is a deliberate security boundary, not an accident: it means `jobs-service` and `applications-service` can only ever be reached through nginx, which is the single point where rate-limiting, security headers, and routing rules are enforced.

### 5.2 – Inter-service communication test (3 pts)

Ran the README's connectivity check from inside `jobs-service` (using a placeholder password so the real credential is never printed to a terminal):
```
psycopg2.OperationalError: connection to server at "postgres" (172.19.0.2), port 5432 failed: FATAL:  password authentication failed for user "postgres"
```
This confirms the full path works: DNS resolution of `postgres` → correct IP (172.19.0.2), TCP connection reaches the Postgres server, and Postgres itself responds with an auth-specific error (not a network-level timeout) — proving connectivity end-to-end; the only reason the test connection didn't fully succeed is the intentionally-wrong placeholder password.

### 5.3 – Nginx routing trace: `POST /api/applications/` (3 pts)

1. **Location block matched:** `location /api/applications` in `nginx/nginx.conf` (prefix match against the path).
2. **Rewrite applied:** `rewrite ^/api/applications/(.*) /applications/$1 break;` — for the exact path `/api/applications/` (no trailing segment), `$1` is empty, so the path becomes `/applications/`, matching the second rule too (`^/api/applications$ /applications`) only if there's no trailing slash; here the first rule fires and produces `/applications/`. The `break` flag stops nginx from evaluating further rewrite rules or re-matching location blocks.
3. **Upstream:** `proxy_pass http://applications_service;` → the `upstream applications_service { server applications-service:3001; }` block, so the rewritten request (`POST /applications/`, headers including `Host`, `X-Real-IP`, `X-Forwarded-For` set by `proxy_set_header`) is forwarded to the `applications-service` container on port 3001. Express's router matches `router.post('/', ...)` (mounted at `/applications` in `src/index.js`) and creates the record.
4. **Response path back to the browser:** `applications-service` returns its JSON response (201 + created record) to nginx over the same proxied connection; nginx passes that response back to the client unmodified except for the security headers it adds on the way out (`X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, and now `Content-Security-Policy` — see Task 6.2) via `add_header ... always`, which applies to every response nginx serves regardless of status code or which location block handled it.

---

## Task 6 — Security Hardening (Bonus, 10 pts)

### 6.1 – Docker secrets (5 pts)

Replaced `POSTGRES_PASSWORD` (a plain env var, visible in `docker inspect <container>` and process listings) with a Docker secret — mounted as a file at `/run/secrets/db_password` inside each container, only readable by that container's own filesystem namespace.

**Setup:**

- `secrets/db_password.txt` holds the real password (gitignored — added `secrets/db_password.txt` to `.gitignore`; `secrets/db_password.txt.example` is committed as a placeholder, mirroring the existing `.env`/`.env.example` pattern).
- `docker-compose.yml`: added a top-level `secrets: { db_password: { file: ./secrets/db_password.txt } }`, and each of `postgres`, `jobs-service`, `applications-service` now declares `secrets: [db_password]`.
- `postgres` uses `POSTGRES_PASSWORD_FILE: /run/secrets/db_password` — the official Postgres image supports this natively (its entrypoint script reads the file itself), so no code change was needed there.
- `jobs-service`/`applications-service` needed real code changes, because **Compose interpolates `${...}` variables into the YAML *before* any container starts** — it has no way to reach into a secret file's contents at that stage. The only place that can read `/run/secrets/db_password` is the running container itself, at its own startup. So instead of building `DATABASE_URL` in `docker-compose.yml`, both services now receive the decomposed pieces (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD_FILE`) as plain (non-secret) env vars, and build `DATABASE_URL` themselves at process startup:
  - `jobs-service/app/database.py`: `_build_database_url()` reads the password file when `POSTGRES_PASSWORD_FILE` is set, otherwise falls back to an explicit `DATABASE_URL` env var (kept for the test suite, which points at SQLite) or the original hardcoded local default.
  - `applications-service/src/db.js`: `buildDatabaseUrl()` mirrors the same logic in Node.

**A second, related bug was fixed as a side effect:** the original Setup Issues section above documents that an unsafe character in `POSTGRES_PASSWORD` broke URL parsing when Compose string-interpolated it directly into `postgresql://user:PASS@host/db`. Building the URL in application code instead of in YAML let us fix this at the root: both `database.py` (`urllib.parse.quote(password, safe='')`) and `db.js` (`encodeURIComponent(password)`) now URL-encode the password before embedding it in the connection string — so a password containing `@`, `/`, `#`, etc. no longer breaks anything, rather than just being a "choose safe characters" rule to remember.

Verified end-to-end: rebuilt both images, wiped the Postgres volume (the password changed, so the old volume's credentials no longer matched — same class of issue documented in the Setup Issues section), brought the full stack up, and all 5 containers reported `healthy` on the first attempt with the new secrets-based auth flow; `GET /api/jobs/` returned the seeded data correctly.

### 6.2 – CSP headers (5 pts)

Added to `nginx/nginx.conf`, alongside the existing `X-Frame-Options`/`X-Content-Type-Options`/`X-XSS-Protection` headers:

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'
```

- `script-src 'self'` — scripts load only from this origin (matches `frontend/index.html`'s single `<script type="module" src="/src/main.jsx">`; no CDN scripts or inline `<script>` blocks exist in this app).
- `style-src 'self' 'unsafe-inline'` — required per the task spec ("styles from `self` and inline"); React/Vite apps commonly need inline styles for CSS-in-JS or dynamically computed inline `style=` attributes, so a stricter `style-src 'self'` alone risked breaking the UI without a nonce-based setup, which was out of scope here.
- `img-src 'self' data:` — added beyond the task's literal wording because `index.html`'s favicon is a `data:image/svg+xml` URI; without allowing `data:` for images, the favicon would be blocked (a real, observed detail in this codebase, not a hypothetical).
- `frame-ancestors 'none'` — blocks all framing, as required; this is the modern CSP replacement for `X-Frame-Options: DENY` and is stricter than the existing `X-Frame-Options: SAMEORIGIN` header (which allows same-origin framing) — kept both for defense-in-depth/older-browser compatibility, but `frame-ancestors 'none'` is what actually governs in CSP-aware browsers.
- `connect-src 'self'` — the app only calls same-origin `/api/...` paths (verified in `frontend/src/api/index.js`), so no external XHR/fetch targets need allowing.

Verified with `curl -sI http://localhost | grep -i content-security` → header present with the exact policy above; also confirmed the frontend (`/`) and jobs API (`/api/jobs/`) both still return `200` after rebuilding nginx with the new config, and `docker compose ps` shows all 5 containers healthy.

**Caveat:** verification here was via HTTP headers and endpoint status codes, not an actual browser session — I can't fully rule out a CSP console violation that only a real browser JS runtime would surface (e.g., if the Vite production build ever emitted an `eval()`-based code path, which `script-src 'self'` without `'unsafe-eval'` would block). Recommended follow-up: open DevTools → Console on `http://localhost` and confirm no CSP violation errors during normal use (browsing jobs, opening the apply modal, submitting an application).

---

## Submission Checklist

- [ ] GitHub repository URL
- [ ] SOLUTION.md complete
- [ ] Screenshot: app running at `http://localhost`
- [ ] Screenshot: `docker compose ps` all healthy
- [ ] Screenshot: successful GitHub Actions pipeline
- [ ] Screenshot: Docker Hub repository with pushed images
- [ ] `backup_*.sql` committed
