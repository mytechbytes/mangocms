# Phoenix/Elixir CI/CD on Oracle Cloud Infrastructure — Complete Setup Guide

**Stack:** Elixir 1.20.1 · OTP 29.0.2 · Phoenix 1.8 · PostgreSQL 16 · Docker · Jenkins · Caddy · Oracle Cloud Infrastructure (OCI)

**Architecture:**
- **Jenkins Server** — Oracle Linux 9, ARM64 (aarch64) — builds, tests, pushes images
- **Production Server** — Ubuntu 24.04, ARM64 (aarch64) — runs the application via Docker Compose
- **Registry** — OCI Container Registry (OCIR), Mumbai region
- **Branches** — `develop` → staging (auto deploy), `main` → production (manual approval)

---

## Part 1 — Prerequisites

### OCI Resources
- Two compute instances (ARM64 Ampere A1 recommended — free tier eligible)
- OCI Container Registry namespace (noted as `<OCI_NAMESPACE>`)
- VCN Security List with ingress rules open for ports 22, 80, 443

### DNS
Point an A record for each app domain to the production server IP before starting Caddy — Let's Encrypt validates via HTTP on port 80.

```
cms.yourdomain.com         → <PRODUCTION_IP>
stg.cms.yourdomain.com     → <PRODUCTION_IP>
```

---

## Part 2 — OCI Setup

### 2.1 Create a Dedicated CI/CD Service Account

> **Critical:** Do NOT use your personal federated (Gmail/IDCS) account for CI/CD. In OCI tenancies with Identity Domains, federated users fail OCIR push with 403 despite correct IAM policies — login succeeds but the IAM authorization check silently fails because the Identity Domain user identity is not matched correctly. Always create a dedicated local IAM user for CI.

**Create a local IAM user:**

OCI Console → Identity & Security → Identity → Domains → Default → Users → **Create User**
- First name: `jenkins`
- Last name: `ci`
- Username: `jenkins-ci`
- **Uncheck** "Use Oracle Identity Cloud Service to manage this user" — this is critical, makes it a local user

**Add to Administrators group:**

Domains → Default → Groups → Administrators → Add Member → select `jenkins-ci`

**Generate auth token:**

Domains → Default → Users → `jenkins-ci` → Auth Tokens → **Generate Token**
- Description: `jenkins-push`
- Copy the token immediately — shown only once, cannot be retrieved again

### 2.2 IAM Policy for OCIR

> **Critical:** In OCI tenancies with Identity Domains, policies must reference groups with the domain-qualified format `'DomainName'/'GroupName'`. The plain `Allow group Administrators` format does not cover Identity Domain users and will result in 403 on push.

OCI Console → Identity & Security → Identity → Policies → **Create Policy**
- Compartment: **root** (tenancy level — must be root, not a sub-compartment)
- Name: `ocir-domain-policy`
- Statements:
```
Allow group 'Default'/'Administrators' to manage repos in tenancy
Allow group 'Default'/'Administrators' to manage all-resources in tenancy
```

### 2.3 Create OCIR Repositories

OCI OCIR does not auto-create repositories on first push — they must exist before the pipeline runs.

OCI Console → Developer Services → Container Registry → **Create Repository** for each:

| Repository | Access | Purpose |
|---|---|---|
| `mangocms` | Private | Application image |
| `mytechbytes-elixir-ci` | Private | Shared CI runner image |

All repositories must be in the **same compartment** covered by the IAM policy.

---

## Part 3 — Jenkins Server Setup (Oracle Linux, ARM64)

SSH in as `opc`:
```bash
ssh opc@<JENKINS_IP>
```

### 3.1 System Updates
```bash
sudo dnf update -y
```

### 3.2 Install Java
```bash
sudo dnf install -y java-17-openjdk
java -version
```

### 3.3 Install Jenkins
```bash
sudo wget -O /etc/yum.repos.d/jenkins.repo \
    https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo dnf install -y jenkins
sudo systemctl enable jenkins
sudo systemctl start jenkins
```

Initial admin password:
```bash
sudo cat /var/lib/jenkins/initialAdminPassword
```

### 3.4 Install Docker
```bash
sudo dnf install -y dnf-utils
sudo dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

### 3.5 Install Git
```bash
sudo dnf install -y git
```

### 3.6 Configure Docker Buildx for ARM64
```bash
docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx ls
```

### 3.7 Configure Docker for OCIR

> **Do not install docker-credential-pass or any GPG-based credential helper.** These cause silent decryption failures in Jenkins non-interactive pipeline shells — `docker login` succeeds but `docker push` fails with 403 because the GPG agent is not accessible. Plain Docker config is the correct and reliable approach for a CI server.

```bash
# Ensure jenkins docker config directory exists and is clean
sudo -u jenkins mkdir -p /var/lib/jenkins/.docker
sudo -u jenkins bash -c 'echo "{}" > /var/lib/jenkins/.docker/config.json'

# Login with the jenkins-ci service account
sudo -u jenkins docker login ap-mumbai-1.ocir.io \
    -u <OCI_NAMESPACE>/jenkins-ci
# enter the auth token generated in Part 2.1

# Verify credentials are stored in plaintext (no credsStore entry)
sudo cat /var/lib/jenkins/.docker/config.json
```

Expected output — auth value present, no `credsStore`:
```json
{
  "auths": {
    "ap-mumbai-1.ocir.io": {
      "auth": "base64encodedtoken..."
    }
  }
}
```

If you see `"credsStore": "pass"` — a docker-credential-pass binary is still in PATH and docker login re-added it. Remove it and reset:
```bash
sudo rm -f /usr/bin/docker-credential-pass /usr/local/bin/docker-credential-pass
sudo -u jenkins bash -c 'echo "{}" > /var/lib/jenkins/.docker/config.json'
# then re-run docker login above
```

### 3.8 Jenkins Credentials

Jenkins UI → Manage Jenkins → Credentials → System → Global:

| ID | Type | Value |
|---|---|---|
| `github-ssh-key-mytechbytes` | SSH Username with private key | GitHub deploy key private key |
| `ocir-credentials` | Username with password | Username: `<OCI_NAMESPACE>/jenkins-ci`, Password: auth token from Part 2.1 |
| `production-server-ssh` | SSH Username with private key | Private key for production server ubuntu user |

### 3.9 Jenkins Plugins

Install via Manage Jenkins → Plugins:
- Pipeline: Multibranch
- Git
- GitHub (for webhook auto-trigger)
- Email Extension
- Timestamper

### 3.10 Email Notification (Gmail SMTP)

Manage Jenkins → System → Email Notification:
```
SMTP server : smtp.gmail.com
SMTP port   : 587
Use TLS     : ✓
Username    : your-email@gmail.com
Password    : Gmail App Password
```

Generate Gmail App Password: Google Account → Security → 2-Step Verification → App Passwords.

### 3.11 Create Multibranch Pipeline Job

Jenkins → New Item → name it `mangocms` → **Multibranch Pipeline**

1. Branch Sources → Add → Git
   - Repository URL: `git@github.com:mytechbytes/mangocms.git`
   - Credentials: `github-ssh-key-mytechbytes`
2. Behaviours → Discover branches: All branches
3. Build Configuration → by Jenkinsfile
4. Scan Triggers → Periodically if not otherwise run → 1 minute

**GitHub Webhook (recommended — instant trigger on push):**

GitHub repo → Settings → Webhooks → Add webhook:
```
Payload URL : http://<JENKINS_IP>:8080/github-webhook/
Content type: application/json
Events      : Just the push event
```

---

## Part 4 — Production Server Setup (Ubuntu, ARM64)

SSH in as `ubuntu`:
```bash
ssh ubuntu@<PRODUCTION_IP>
```

### 4.1 System Updates
```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### 4.2 Install Docker
```bash
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker ubuntu
newgrp docker
```

### 4.3 Configure Docker for OCIR

Same rule as Jenkins — do not use docker-credential-pass.

```bash
mkdir -p ~/.docker
echo "{}" > ~/.docker/config.json

docker login ap-mumbai-1.ocir.io \
    -u <OCI_NAMESPACE>/jenkins-ci
# enter the auth token

# Verify — should show auth value, no credsStore
cat ~/.docker/config.json
```

If `"credsStore": "pass"` appears, remove the helper and reset:
```bash
sudo rm -f /usr/bin/docker-credential-pass /usr/local/bin/docker-credential-pass
echo "{}" > ~/.docker/config.json
# re-run docker login
```

### 4.4 Create Application Directory Structure
```bash
mkdir -p /home/ubuntu/apps/data/{postgres,redis}
mkdir -p /home/ubuntu/apps-stg/data/{postgres,redis}
```

### 4.5 Production `.env`
```bash
cat > /home/ubuntu/apps/.env << 'EOF'
OCI_NAMESPACE=<your-oci-namespace>

POSTGRES_USER=postgres
POSTGRES_PASSWORD=<strong-password>
POSTGRES_CMS_DB=mangocms_prod

REDIS_PASSWORD=<strong-password>

CMS_IMAGE_TAG=prd-latest
CMS_SECRET_KEY_BASE=<64-char-random-string>
EOF
chmod 600 /home/ubuntu/apps/.env
```

Generate secret key: `openssl rand -hex 64`

### 4.6 Staging `.env`
```bash
cat > /home/ubuntu/apps-stg/.env << 'EOF'
OCI_NAMESPACE=<your-oci-namespace>

POSTGRES_USER=postgres
POSTGRES_PASSWORD=<strong-password>
POSTGRES_CMS_DB=mangocms_stg

REDIS_PASSWORD=<strong-password>

CMS_STG_IMAGE_TAG=stg-latest
CMS_SECRET_KEY_BASE=<64-char-random-string>
EOF
chmod 600 /home/ubuntu/apps-stg/.env
```

### 4.7 Production `docker-compose.yml`
```bash
cat > /home/ubuntu/apps/docker-compose.yml << 'EOF'
networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge

volumes:
  postgres-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/ubuntu/apps/data/postgres
  redis-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/ubuntu/apps/data/redis
  caddy_data:
  caddy_config:

services:

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - frontend-net
    depends_on:
      - cms

  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - backend-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - redis-data:/data
    networks:
      - backend-net
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  cms:
    image: ap-mumbai-1.ocir.io/${OCI_NAMESPACE}/mangocms:${CMS_IMAGE_TAG}
    container_name: cms
    restart: unless-stopped
    environment:
      DATABASE_URL: ecto://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres/${POSTGRES_CMS_DB}
      SECRET_KEY_BASE: ${CMS_SECRET_KEY_BASE}
      PHX_HOST: cms.yourdomain.com
      PORT: 4000
      POOL_SIZE: 10
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
    networks:
      - frontend-net
      - backend-net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
```

### 4.8 Staging `docker-compose.yml`
```bash
cat > /home/ubuntu/apps-stg/docker-compose.yml << 'EOF'
networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge

volumes:
  postgres-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/ubuntu/apps-stg/data/postgres
  redis-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/ubuntu/apps-stg/data/redis

services:

  postgres:
    image: postgres:16-alpine
    container_name: postgres-stg
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - backend-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: redis-stg
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - redis-data:/data
    networks:
      - backend-net
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  cms-stg:
    image: ap-mumbai-1.ocir.io/${OCI_NAMESPACE}/mangocms:${CMS_STG_IMAGE_TAG}
    container_name: cms-stg
    restart: unless-stopped
    environment:
      DATABASE_URL: ecto://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-stg/${POSTGRES_CMS_DB}
      SECRET_KEY_BASE: ${CMS_SECRET_KEY_BASE}
      PHX_HOST: stg.cms.yourdomain.com
      PORT: 4000
      POOL_SIZE: 5
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis-stg:6379/0
    networks:
      - frontend-net
      - backend-net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
```

### 4.9 Caddyfile

> **Critical:** Caddy must be on `frontend-net` — the same Docker network as the app containers. Without this, Caddy cannot reach `cms:4000` and returns 502 for all requests.

```bash
cat > /home/ubuntu/apps/Caddyfile << 'EOF'
cms.yourdomain.com {
    reverse_proxy cms:4000
}

stg.cms.yourdomain.com {
    reverse_proxy cms-stg:4000
}
EOF
```

### 4.10 Start Services and Create Databases
```bash
# Production
cd /home/ubuntu/apps
docker compose up -d postgres
sleep 5
docker compose exec postgres createdb -U postgres mangocms_prod
docker compose up -d
docker compose logs -f caddy    # watch for TLS cert issuance

# Staging
cd /home/ubuntu/apps-stg
docker compose up -d postgres
sleep 5
docker compose exec postgres createdb -U postgres mangocms_stg
docker compose up -d
```

### 4.11 Verify
```bash
curl -s https://cms.yourdomain.com/health
# → {"status":"ok","db":"ok"}

curl -s https://stg.cms.yourdomain.com/health
# → {"status":"ok","db":"ok"}
```

---

## Part 5 — Application Repository Setup

### 5.1 Key Files

**`Dockerfile`** — multi-stage build (deps → builder → assets → release → runtime):
- Builder: `FROM elixir:1.20.1-otp-29` (Debian trixie — glibc 2.41, OpenSSL 3.5)
- Runtime: `FROM debian:trixie-slim` — must match builder OS exactly
- Add `libsctp1` to runtime to silence Erlang ESOCK warning on startup
- Non-root user `appuser:appgroup` at UID/GID 1000

> **Why trixie-slim?** `elixir:1.20.1-otp-29` is built on Debian trixie. `debian:bookworm-slim` fails with `glibc version not found` (2.36 < 2.38 required). `ubuntu:24.04` fails with OpenSSL mismatch (3.0 < 3.4 required by crypto NIF).

**`ci/Dockerfile`** — shared Elixir CI runner, used across all app pipelines:
```dockerfile
FROM elixir:1.20.1-otp-29-alpine
RUN apk add --no-cache git build-base curl bash python3
RUN mix local.hex --force && mix local.rebar --force
WORKDIR /app
```

**`.tool-versions`** — must match actual OTP version in the Docker image:
```
erlang 29.0.2
elixir 1.20.1-otp-29
```

> `elixir:1.20.1-otp-29` ships OTP `29.0.2` not `29.0.1`. Dialyzer embeds the OTP version in the PLT filename — a mismatch forces PLT rebuild on every run.

**`coveralls.json`**:
```json
{
  "coverage_options": {
    "treat_no_relevant_lines_as_covered": true,
    "output_dir": "cover/"
  },
  "skip_files": [
    "test/support/",
    "lib/mangocms/release.ex",
    "lib/mangocms/application.ex",
    "lib/mangocms_web.ex",
    "lib/mangocms_web/components/core_components.ex",
    "lib/mangocms_web/controllers/health_controller.ex"
  ]
}
```

**`.dialyzer_ignore.exs`** — clear after Elixir/OTP upgrades, stale patterns cause `Unnecessary Skips` errors:
```elixir
[]
```

**`lib/mangocms/release.ex`** — required for production migrations (`@moduledoc false` required for Credo strict):
```elixir
defmodule MangoCMS.Release do
  @moduledoc false
  @app :mangocms

  def migrate do
    load_app()
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
```

---

## Part 6 — Jenkins Pipeline

### 6.1 Branch Behaviour

| Branch | CI | Deploy | Image tags |
|---|---|---|---|
| `develop` | auto on push | auto (no approval) | `stg-N` / `stg-latest` |
| `main` | auto on push | **manual approval** in Jenkins UI | `prd-N` / `prd-latest` |
| other | CI only | skipped | `pr-N` |

### 6.2 Shared CI Image

Stored in OCIR, shared across all Elixir app pipelines on the Jenkins server:
```
ap-mumbai-1.ocir.io/<OCI_NAMESPACE>/mytechbytes-elixir-ci:1.20.1-otp-29
```

Only rebuilds when `REBUILD_CI_IMAGE=true` or image is missing in OCIR. Set `REBUILD_CI_IMAGE=true` when upgrading Elixir/OTP version.

### 6.3 Pipeline Stages

| Stage | Purpose |
|---|---|
| Configure | Set branch-specific env vars (host, container name, image tags) |
| CI Image | Build/push shared CI image to OCIR if missing or forced |
| Checkout | Clone repo, capture git commit/branch |
| CI Infrastructure | Create network, start postgres, wait for readiness |
| Setup | `mix deps.get`, `mix ecto.create && migrate` |
| Compile | `mix compile --warnings-as-errors` |
| Quality Checks | Credo strict + Dialyzer (parallel) |
| Tests & Coverage | `mix coveralls.json`, check threshold |
| Build & Push | `docker buildx build --platform linux/arm64`, push to OCIR |
| Approval | **main only** — pauses, waits for human to click Deploy (24h timeout) |
| Deploy | Update `.env`, pull image, recreate container, run migrations, verify |
| Smoke Test | HTTP GET `/health` up to 5 attempts |
| Rollback | Validate tag in OCIR, update `.env` + pull, recreate, verify |

### 6.4 Pipeline Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `PIPELINE_ACTION` | `BUILD_AND_DEPLOY` | `BUILD_AND_DEPLOY` or `ROLLBACK` |
| `ROLLBACK_TAG` | — | `prd-13` (main) or `stg-13` (develop) |
| `COVERAGE_THRESHOLD` | `80` | Minimum coverage % |
| `REBUILD_CI_IMAGE` | `false` | Force rebuild of shared CI image |

### 6.5 Run Migrations Manually
```bash
# Production
docker exec cms /app/bin/mangocms eval "MangoCMS.Release.migrate()"

# Staging
docker exec cms-stg /app/bin/mangocms eval "MangoCMS.Release.migrate()"
```

---

## Part 7 — OCI Email Delivery Setup

### 7.1 Configure Email Domain

OCI Console → **Email Delivery** → **Email Domains** → **Create Email Domain**
- Domain: `yourdomain.com`
- Click **Create**

After creation, open the domain and configure:

**SPF** — OCI shows a TXT record to add to your DNS. Add it at your DNS provider:
```
Type : TXT
Name : @  (or yourdomain.com)
Value: v=spf1 include:rp.oracleemaildelivery.com ~all
```

**DKIM** — OCI creates a DKIM key. Click the DKIM entry → copy the CNAME record:
```
Type  : CNAME
Name  : <selector>._domainkey   (e.g. mangocms-bom-202606._domainkey)
Value : <selector>.yourdomain.com.dkim.<region>.oracleemaildelivery.com
```

After adding both DNS records, OCI verifies them automatically within 5–30 minutes. Status changes to **Active**.

### 7.2 Add Approved Sender

OCI Console → **Email Delivery** → **Approved Senders** → **Create Approved Sender**
- Email: `no-reply@yourdomain.com`
- Click **Create**

> **Critical:** The FROM address used in your application must exactly match an approved sender. The Phoenix generator uses `contact@example.com` by default — update it to your actual sender address before deploying.

Wait 10–15 minutes for the approved sender to propagate to OCI's SMTP relay before testing.

### 7.3 Generate SMTP Credentials

SMTP credentials are tied to a specific IAM user. Use the same `jenkins-ci` local IAM user.

OCI Console → **Identity & Security** → **Identity** → **Domains** → Default → **Users** → `jenkins-ci` → **SMTP Credentials** → **Generate SMTP Credentials**
- Description: `mangocms-smtp`
- Copy the **username** and **password** immediately — shown only once

The SMTP username format looks like:
```
ocid1.user.oc1..xxxxx@ocid1.tenancy.oc1..xxxxx.4r.com
```

### 7.4 SMTP Connection Details (Mumbai region)

```
Server : smtp.email.ap-mumbai-1.oci.oraclecloud.com
Port   : 587  (STARTTLS)
Auth   : Always
TLS    : if_available
```

> **Port 465 vs 587:** OCI Email Delivery uses port 587 with STARTTLS. Using `tls: :always` forces SSL from the first byte (port 465 behaviour) and causes `tls_failed`. Use `tls: :if_available` with port 587.

### 7.5 Add SMTP Vars to Production `.env`

```bash
cat >> /home/ubuntu/apps/.env << 'EOF'

SMTP_SERVER=smtp.email.ap-mumbai-1.oci.oraclecloud.com
SMTP_PORT=587
SMTP_USERNAME=<smtp-username-from-7.3>
SMTP_PASSWORD=<smtp-password-from-7.3>
SMTP_FROM=no-reply@yourdomain.com
EOF
```

### 7.6 Add SMTP Vars to `docker-compose.yml`

Add these to the `environment:` block of your app service in `docker-compose.yml`:

```yaml
  cms:
    environment:
      # ... existing vars ...
      SMTP_SERVER: ${SMTP_SERVER}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_USERNAME: ${SMTP_USERNAME}
      SMTP_PASSWORD: ${SMTP_PASSWORD}
      SMTP_FROM: ${SMTP_FROM}
```

> **Why explicit?** Docker Compose does not automatically pass all `.env` vars into containers. Only vars listed in `environment:` are injected. Verify with `docker compose config | grep SMTP` — if empty, the service block is missing the env keys.

Restart the app container after editing:
```bash
docker compose up -d --no-deps cms
```

### 7.7 Phoenix App Changes

**`mix.exs`** — add `:ssl` and `:crypto` to `extra_applications`:
```elixir
def application do
  [
    mod: {MyApp.Application, []},
    extra_applications: [:logger, :runtime_tools, :ssl, :crypto]
  ]
end
```

> Without `:ssl` in the release, the SMTP TLS handshake silently fails. The error `SSL not started` appears in eval context. The application may start fine but email delivery returns `{:error, ...}` on every send.

**`mix.exs`** — add `gen_smtp` dependency:
```elixir
{:swoosh, "~> 1.16"},
{:gen_smtp, "~> 1.2"},
```

**`config/runtime.exs`** — optional SMTP config (falls back to no-op if vars absent):
```elixir
if System.get_env("SMTP_SERVER") do
  config :myapp, MyApp.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.get_env("SMTP_SERVER"),
    port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    tls: :if_available,
    auth: :always,
    from_email: System.get_env("SMTP_FROM"),
    tls_options: [verify: :verify_none]
end
```

**`lib/myapp/accounts/user_notifier.ex`** — use the SMTP_FROM env var, not the hardcoded Phoenix default:
```elixir
# WRONG — default Phoenix generator value, not an approved OCI sender
|> from({"MyApp", "contact@example.com"})

# CORRECT
|> from({"MyApp", System.get_env("SMTP_FROM", "no-reply@yourdomain.com")})
```

**Handle delivery errors in LiveViews** — the default Phoenix generator hard-matches `{:ok, _}` which crashes the LiveView on SMTP failure:
```elixir
# WRONG — crashes LiveView if SMTP fails
{:ok, _} = Accounts.deliver_login_instructions(user, url_fun)

# CORRECT — handle failure gracefully
case Accounts.deliver_login_instructions(user, url_fun) do
  {:ok, _} ->
    {:noreply, socket |> put_flash(:info, "Email sent.") |> push_navigate(to: ~p"/users/log-in")}
  {:error, _} ->
    {:noreply, socket |> put_flash(:error, "Could not send email. Please try again later.") |> push_navigate(to: ~p"/users/log-in")}
end
```

### 7.8 Test SMTP from Running Container

```bash
# Test via the running application node (not eval — eval starts a separate minimal VM)
docker exec cms /app/bin/mangocms rpc "
  result = MangoCMS.Mailer.deliver(%Swoosh.Email{
    from: {\"MyApp\", System.get_env(\"SMTP_FROM\")},
    to: [{\"Test\", \"you@email.com\"}],
    subject: \"SMTP Test\",
    text_body: \"OCI SMTP is working.\"
  })
  IO.inspect(result, label: \"SMTP Result\")
"
# Expected: SMTP Result: {:ok, "Ok\r\n"}
```

### 7.9 Common SMTP Errors

| Error | Cause | Fix |
|---|---|---|
| `SSL not started` | `:ssl` not in `extra_applications` in mix.exs | Add `:ssl, :crypto` to extra_applications, rebuild |
| `535 Authorization failed: Envelope From address not authorized` | FROM address not an approved sender in OCI | Add sender to Approved Senders in OCI Console — wait 15 min to propagate |
| `535 Authorization failed` — sender is approved | Approved sender was just created, not propagated yet | Wait 10–15 minutes, retry |
| `535 Authorization failed` — default Phoenix FROM | `contact@example.com` left unchanged in `user_notifier.ex` | Update `from` to use `SMTP_FROM` env var |
| `tls_failed` | `tls: :always` forces SSL from first byte, incompatible with STARTTLS on port 587 | Change to `tls: :if_available` |
| No email, no error log | `{:ok, _} = Mailer.deliver(...)` crashes LiveView, crash is caught upstream | Replace hard match with `case`, handle `{:error, _}` |
| SMTP vars not reaching container | Vars in `.env` but not listed in `environment:` in docker-compose.yml | Add explicit `SMTP_SERVER: ${SMTP_SERVER}` etc. to service environment block |

---

## Part 8 — Adding a New App

1. **OCI** — Create repository `<appname>` in Container Registry (same compartment)
2. **OCI Email** — Add approved sender `no-reply@yourdomain.com` (if not already added for domain)
3. **DNS** — Add A record pointing new domain to production server IP
4. **Production server** — Add service to `docker-compose.yml`, add env vars to `.env`, create database:
   ```bash
   docker compose exec postgres createdb -U postgres <appname>_prod
   ```
5. **Caddyfile** — Add block and reload (zero-downtime):
   ```
   appname.yourdomain.com {
       reverse_proxy appname:4000
   }
   ```
   ```bash
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
6. **New app repo** — Copy `Jenkinsfile`, update `IMAGE_NAME` and the branch-specific `CONTAINER_NAME`/`ENV_VAR_NAME`/`APP_URL` values in the Configure stage
7. **Phoenix app** — Update `user_notifier.ex` FROM address, add `:ssl, :crypto` to extra_applications, add `gen_smtp` dep, add SMTP config to runtime.exs
8. **Jenkins** — Create new Multibranch Pipeline job pointing to the new repo

---

## Part 9 — Useful Commands

```bash
# Application logs
docker logs -f cms
docker logs --tail 100 cms
docker compose logs -f

# Container status
docker compose ps -a

# Restart a service
docker compose restart cms

# Run migrations manually
docker exec cms /app/bin/mangocms eval "MangoCMS.Release.migrate()"

# Reload Caddy config without downtime
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## Part 10 — Production Monitoring

### What to Check Regularly

| Check | Command | Expected |
|---|---|---|
| Container uptime | `docker ps` | `cms` uptime in days, not minutes |
| Health endpoint | `curl -s https://cms.yourdomain.com/health` | `{"status":"ok","db":"ok"}` |
| Container logs | `docker logs --tail 50 cms` | No `[error]` entries |
| Disk space | `df -h` | `<80%` on `/` |
| SMTP delivery | RPC test (see Part 7.8) | `{:ok, "Ok\r\n"}` |

### Monthly Tasks
- **SMTP test** — send a test email via RPC to confirm OCI Email Delivery is live
- **OCIR cleanup** — prune old `prd-N` images; only keep last 10:
  ```bash
  # List images in OCIR — delete old ones via OCI Console or OCI CLI
  oci artifacts container image list --compartment-id <compartment-ocid> --repository-name mangocms
  ```
- **Disk space** — Docker images accumulate; prune unused:
  ```bash
  docker image prune -f
  ```

### Annual Tasks
- **OCI Auth Token rotation** — tokens expire after 1 year; regenerate for `jenkins-ci` and update Jenkins `ocir-credentials` credential
- **DKIM key rotation** — OCI allows rotating DKIM keys; update DNS CNAME after rotation

### Key Gotchas to Never Forget
1. **docker-credential-pass** — if a new Jenkins or production server is set up, remove this binary before running any pipeline. It silently breaks all `docker push` with 403.
2. **SMTP FROM must be an approved sender** — the Phoenix generator uses `contact@example.com`; always update `user_notifier.ex` before the first email-sending deploy.
3. **`eval` vs `rpc`** — `eval` starts a minimal VM (only kernel/stdlib). Use `rpc` to run code in the context of the live running Phoenix node. SSL, config, and env vars are only available via `rpc`.
4. **OCIR repos must be pre-created** — first push fails if the repo doesn't exist in OCI Console.
5. **Approved sender propagation** — after creating an approved sender in OCI, wait 10–15 minutes before testing SMTP; 535 errors during this window are normal.

---

## Common Issues & Fixes

| Issue | Cause | Fix |
|---|---|---|
| `403 Forbidden` on push — login succeeds | Federated (Gmail/IDCS) user — IAM policy can't match identity for push authorization | Create a local IAM user (`jenkins-ci`) in Identity Domains, never use personal federated accounts for CI |
| `403 Forbidden` on push — login succeeds | `"credsStore": "pass"` in docker config — GPG agent not running in Jenkins pipeline shell, credentials silently fail | `sudo rm -f /usr/bin/docker-credential-pass /usr/local/bin/docker-credential-pass`, reset config to `{}`, re-login |
| `"credsStore": "pass"` returns after reset | docker-credential-pass binary still in PATH, docker login re-adds it automatically | Remove both `/usr/bin` and `/usr/local/bin` copies |
| `Allow group Administrators` policy has no effect | Identity Domains tenancy requires domain-qualified group name | Use `Allow group 'Default'/'Administrators'` format |
| `403` on OCIR push — repo doesn't exist | OCIR does not auto-create repos | Create repository manually in OCI Console → Container Registry before first push |
| `glibc version not found` at container start | Runtime OS doesn't match builder | Use `debian:trixie-slim` as runtime — same Debian release as `elixir:1.20.1-otp-29` |
| `ESOCK WARNING: libsctp.so.1` | Missing SCTP library in slim image | Add `libsctp1` to runtime Dockerfile apt-get |
| `groupadd: GID 1000 already exists` | Base image ships a default user at UID 1000 | Add `userdel -r "$(getent passwd 1000 ...)" 2>/dev/null \|\| true` before `groupadd` |
| `Dialyzer Unnecessary Skips` | Stale ignore patterns after Elixir/OTP upgrade | Clear `.dialyzer_ignore.exs` to `[]` |
| `Exec format error` on downloaded binary | Wrong architecture — assumed amd64, server is arm64 | Run `uname -m` first — use `linux-arm64` for aarch64 |
| `BRANCH_NAME` empty in pipeline | Regular Pipeline job, not Multibranch | Convert job to Multibranch Pipeline |
| 502 Bad Gateway from Caddy | Caddy not on same Docker network as app containers | Add `networks: - frontend-net` to Caddy service in docker-compose.yml |
| Smoke test HTTP 000 | Container not running or Caddy not started | Check `docker compose ps`, check Caddy logs |
| `SSL not started` on SMTP | `:ssl` missing from `extra_applications` in mix.exs | Add `:ssl, :crypto`, rebuild release |
| `535 Authorization failed: Envelope From not authorized` | FROM address not an approved sender, or sender not propagated yet | Add sender in OCI → Approved Senders, wait 15 min |
| `535` with default Phoenix FROM | `contact@example.com` left in `user_notifier.ex` | Change to `System.get_env("SMTP_FROM", "no-reply@yourdomain.com")` |
| `tls_failed` on SMTP | `tls: :always` incompatible with STARTTLS on port 587 | Change to `tls: :if_available` in runtime.exs |
| SMTP vars not reaching container | Vars in `.env` but not listed in `environment:` in docker-compose.yml | Add explicit `SMTP_SERVER: ${SMTP_SERVER}` etc. to service block |
| LiveView crashes on registration | `{:ok, _} = Mailer.deliver(...)` hard-match crashes on SMTP error | Replace with `case` statement, handle `{:error, _}` |
| `docker compose config \| grep SMTP` returns nothing | App service missing SMTP env keys | Add vars to `environment:` block and restart container |
