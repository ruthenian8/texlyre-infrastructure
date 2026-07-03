# Re-architecture instructions: TeXlyre on a Hugging Face Docker Space using the published TeX Live base image

## Goal

Deploy a self-hosted TeXlyre instance for a small team on one Hugging Face Docker Space.

The TeX Live on-demand server has already been compiled and published as:

```text
ruthenian8/texlyre-texlive-ondemand-server
```

This image is now the runtime foundation. Do not reinstall `texlive-full` inside the Hugging Face Space build.

The Hugging Face Space image should only add:

* TeXlyre frontend;
* y-webrtc server;
* PeerJS server;
* FilePizza server;
* Redis;
* Nginx;
* Supervisor;
* Hugging Face-specific routing and config.

## Architecture

Run one Docker container inside one Hugging Face Docker Space.

Inside that container:

```text
HF public URL
   ↓
Nginx on port 7860
   ├── /texlyre/       → static TeXlyre frontend
   ├── /api/texlive/   → Python TeX Live on-demand server from base image
   ├── /ywebrtc/       → y-webrtc signaling
   ├── /peerjs/        → PeerJS signaling
   └── /filepizza/     → FilePizza
```

Use Supervisor to run all internal services.

Remove Traefik and Portainer from this deployment path. They are only useful for the original Docker Compose/VPS architecture.

## Step 1 — Create the HF deployment directory

Add a deployment target to the repo:

```text
deploy/hf-space/
├── Dockerfile
├── README.md
├── supervisord.conf
├── nginx/
│   └── nginx.conf
├── entrypoint.sh
├── texlyre.config.hf.ts
├── userdata.hf.template.json
└── .dockerignore
```

Keep the original `docker-compose.yml` untouched.

For the actual Hugging Face Space repository, copy or mirror these files so that `Dockerfile` and `README.md` are at the Space repo root.

## Step 2 — Use the published TeX Live image as the final base

The HF Dockerfile must start from:

```dockerfile
FROM ruthenian8/texlyre-texlive-ondemand-server:<tag-or-digest>
```

Prefer pinning by digest once the image is stable:

```dockerfile
FROM ruthenian8/texlyre-texlive-ondemand-server@sha256:<digest>
```

Do not use:

```dockerfile
RUN apt-get install texlive-full
```

inside the HF Space Dockerfile.

That has already been done in the base image.

## Step 3 — HF Space Dockerfile

Use this as the deployment Dockerfile pattern.

```dockerfile
# ---- Stage 1: frontend build ----
FROM node:20-bookworm AS frontend-build

WORKDIR /src/frontend/texlyre

COPY frontend/texlyre/package*.json ./
RUN npm ci

COPY frontend/texlyre/ ./
COPY deploy/hf-space/texlyre.config.hf.ts ./texlyre.config.ts

RUN npm run generate:configs
RUN npm run build


# ---- Stage 2: y-webrtc ----
FROM node:20-bookworm AS ywebrtc-build

WORKDIR /src/y-webrtc-server

COPY services/y-webrtc-server/package*.json ./
RUN npm ci --omit=dev

COPY services/y-webrtc-server/ ./


# ---- Stage 3: PeerJS ----
FROM node:20-bookworm AS peerjs-build

WORKDIR /src/peerjs-server

COPY services/peerjs-server/package*.json ./
RUN npm ci

COPY services/peerjs-server/ ./
RUN npm run build
RUN npm ci --omit=dev


# ---- Stage 4: FilePizza ----
FROM node:20-bookworm AS filepizza-build

RUN corepack enable

WORKDIR /src/filepizza-server

COPY services/filepizza-server/package.json services/filepizza-server/pnpm-lock.yaml services/filepizza-server/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

COPY services/filepizza-server/ ./
RUN pnpm build


# ---- Final HF runtime image ----
FROM ruthenian8/texlyre-texlive-ondemand-server:<tag-or-digest>

ENV DEBIAN_FRONTEND=noninteractive

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    redis-server \
    curl \
    ca-certificates \
    nodejs \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 user || true

WORKDIR /app

COPY --from=frontend-build --chown=user:user /src/frontend/texlyre/dist ./frontend

COPY --from=ywebrtc-build --chown=user:user /src/y-webrtc-server ./services/y-webrtc-server

COPY --from=peerjs-build --chown=user:user /src/peerjs-server ./services/peerjs-server

COPY --from=filepizza-build --chown=user:user /src/filepizza-server/.next/standalone ./services/filepizza-server
COPY --from=filepizza-build --chown=user:user /src/filepizza-server/public ./services/filepizza-server/public
COPY --from=filepizza-build --chown=user:user /src/filepizza-server/.next/static ./services/filepizza-server/.next/static

COPY deploy/hf-space/nginx/nginx.conf /etc/nginx/nginx.conf
COPY deploy/hf-space/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY deploy/hf-space/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
 && mkdir -p /tmp/nginx /tmp/redis /tmp/supervisor /app/run \
 && chown -R user:user /app /tmp/nginx /tmp/redis /tmp/supervisor /app/run

USER user

ENV HOME=/home/user
ENV PATH=/home/user/.local/bin:$PATH

EXPOSE 7860

CMD ["/entrypoint.sh"]
```

## Step 4 — Validate the base image layout

Before wiring Supervisor, inspect the published base image.

Run locally:

```bash
docker run --rm -it ruthenian8/texlyre-texlive-ondemand-server:<tag> /bin/bash
```

Inside the container, verify:

```bash
pwd
ls
find / -name wsgi.py 2>/dev/null | head
python3 --version
which python3
which kpsewhich
```

Find the actual TeX Live server app directory.

The expected service command is probably:

```bash
python3 wsgi.py
```

But the correct `directory=` in Supervisor depends on where the base image stores the app.

Use one of these patterns:

```ini
directory=/app
command=python3 wsgi.py
```

or:

```ini
directory=/opt/texlive-ondemand-server
command=python3 wsgi.py
```

Do not guess. Verify the base image path once and then hardcode it.

## Step 5 — Entrypoint

Create `entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/nginx/client_body \
         /tmp/nginx/proxy \
         /tmp/nginx/fastcgi \
         /tmp/nginx/uwsgi \
         /tmp/nginx/scgi \
         /tmp/redis \
         /tmp/supervisor

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
```

Make sure it is executable:

```bash
chmod +x deploy/hf-space/entrypoint.sh
```

## Step 6 — Supervisor config

Use this as the starting `supervisord.conf`.

Adjust only the TeX Live `directory=` after inspecting the base image.

```ini
[supervisord]
nodaemon=true
logfile=/tmp/supervisor/supervisord.log
pidfile=/tmp/supervisor/supervisord.pid

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
priority=1
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:redis]
command=redis-server --port 6380 --bind 127.0.0.1 --dir /tmp/redis --save "" --appendonly no --protected-mode yes
autostart=true
autorestart=true
priority=2
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:texlive-server]
directory=/app
command=python3 wsgi.py
environment=PORT="3001",REDIS_PORT="6380",API_ORIGINS="*"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:ywebrtc-server]
directory=/app/services/y-webrtc-server
command=node ./bin/server.js
environment=NODE_ENV="production",PORT="3002",API_ORIGINS="*"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
stderr_logfile=/dev/stderr

[program:peerjs-server]
directory=/app/services/peerjs-server
command=node dist/bin/peerjs.js --port 3003 --path /texlyre --key peerjs --proxied true --allow_discovery false
environment=NODE_ENV="production",PORT="3003",PEERJS_PORT="3003",PEERJS_PATH="/texlyre",PEERJS_KEY="peerjs",PEERJS_PROXIED="true",PEERJS_ALLOW_DISCOVERY="false",PEERJS_CONCURRENT_LIMIT="5000"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:filepizza-server]
directory=/app/services/filepizza-server
command=node server.js
environment=NODE_ENV="production",PORT="3004",REDIS_URL="redis://127.0.0.1:6380",API_ORIGINS="*",PEERJS_SERVERS="/peerjs/texlyre"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
```

Action points:

* Confirm the TeX Live app directory.
* Confirm the y-webrtc start command.
* Confirm the PeerJS build output path.
* Confirm FilePizza starts from `.next/standalone/server.js`.
* Keep Redis bound to `127.0.0.1`.

## Step 7 — Nginx config

Create `nginx/nginx.conf`:

```nginx
worker_processes 1;
pid /tmp/nginx.pid;

events {
  worker_connections 1024;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  access_log /dev/stdout;
  error_log /dev/stderr warn;

  client_body_temp_path /tmp/nginx/client_body;
  proxy_temp_path /tmp/nginx/proxy;
  fastcgi_temp_path /tmp/nginx/fastcgi;
  uwsgi_temp_path /tmp/nginx/uwsgi;
  scgi_temp_path /tmp/nginx/scgi;

  sendfile on;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen 7860;
    server_name _;

    location = / {
      return 302 /texlyre/;
    }

    location /health {
      return 200 "OK\n";
      add_header Content-Type text/plain;
    }

    location /texlyre/ {
      alias /app/frontend/;
      try_files $uri $uri/ /texlyre/index.html;
    }

    location /api/texlive/ {
      proxy_pass http://127.0.0.1:3001/;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_read_timeout 600s;
    }

    location /ywebrtc/ {
      proxy_pass http://127.0.0.1:3002/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
    }

    location /peerjs/ {
      proxy_pass http://127.0.0.1:3003/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
    }

    location /filepizza/ {
      proxy_pass http://127.0.0.1:3004/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
    }
  }
}
```

## Step 8 — TeXlyre frontend config

Do not invent generic `VITE_*` variables unless TeXlyre actually supports them.

Use TeXlyre’s config generation flow.

Create `texlyre.config.hf.ts` or patch the existing `texlyre.config.ts` during build so that generated user settings point to the HF Space routes.

Target generated settings:

```json
{
  "settings": {
    "collab-signaling-servers": "wss://<space-subdomain>.hf.space/ywebrtc/",
    "file-sync-server-url": "https://<space-subdomain>.hf.space/filepizza",
    "latex-texlive-endpoint": "https://<space-subdomain>.hf.space/api/texlive"
  }
}
```

For local testing:

```json
{
  "settings": {
    "collab-signaling-servers": "ws://localhost:7860/ywebrtc/",
    "file-sync-server-url": "http://localhost:7860/filepizza",
    "latex-texlive-endpoint": "http://localhost:7860/api/texlive"
  }
}
```

Recommended action:

* Build once with hardcoded HF URLs.
* Later improve portability by deriving same-origin URLs from `window.location`.

## Step 9 — Hugging Face Space README

At the root of the Space repo, create `README.md`:

```yaml
---
title: TeXlyre
emoji: 📝
colorFrom: blue
colorTo: gray
sdk: docker
app_port: 7860
pinned: false
startup_duration_timeout: 30m
---
```

Then add normal README content below the YAML frontmatter.

## Step 10 — Persistence

Do not use HF persistent storage for TeX Live.

The TeX Live tree is already inside:

```text
ruthenian8/texlyre-texlive-ondemand-server
```

Use persistence only for data that actually changes at runtime.

Policy:

* TeX Live packages: baked into the base image.
* Redis: ephemeral.
* FilePizza sessions: ephemeral.
* y-webrtc state: ephemeral.
* Compiled output cache: ephemeral unless later proven useful.
* User projects: browser-local plus Git sync, not Space filesystem.
* Logs/artifacts: optional HF Storage Bucket.

Do not write application-critical state into the container filesystem.

## Step 11 — Secrets and variables

Use Hugging Face Space settings for secrets and variables.

Keep out of the Dockerfile:

* registry credentials;
* Git tokens;
* Redis password, if used;
* API keys;
* any team-specific credentials.

If the DockerHub image is public, no registry secret is needed.

If it becomes private, configure Hugging Face so the Space can pull it before relying on it.

## Step 12 — Local smoke test

Before pushing to HF, build locally:

```bash
docker build -f deploy/hf-space/Dockerfile -t texlyre-hf-space .
```

Run locally:

```bash
docker run --rm -p 7860:7860 texlyre-hf-space
```

Test:

```bash
curl http://localhost:7860/health
open http://localhost:7860/texlyre/
```

Then check:

* frontend loads;
* TeX Live endpoint responds through `/api/texlive/`;
* y-webrtc WebSocket route upgrades;
* PeerJS route responds;
* FilePizza route loads;
* no service immediately exits in Supervisor logs.

## Step 13 — Deploy to Hugging Face

Push the Space repo:

```bash
git remote add hf https://huggingface.co/spaces/<user-or-org>/<space-name>
git push hf main
```

Watch the Space logs.

The build should not contain:

```text
apt-get install texlive-full
```

If it does, the Dockerfile is wrong.

Expected deploy behavior:

* DockerHub image pulls first.
* Node services build.
* frontend builds.
* Nginx/Supervisor/Redis are installed.
* final container starts on port `7860`.
* root redirects to `/texlyre/`.

## Step 14 — Rollout checklist

Before using it with a team, confirm:

* `/health` returns 200.
* `/texlyre/` loads.
* root `/` redirects to `/texlyre/`.
* browser console has no CORS errors.
* browser console has no mixed-content errors.
* TeX Live server starts from the DockerHub base image.
* TeX package lookup works through `/api/texlive/`.
* two browser tabs see live edits through `/ywebrtc/`.
* PeerJS works through `/peerjs/`.
* FilePizza loads through `/filepizza/`.
* P2P file transfer works between two different networks.
* Redis is not externally exposed.
* HF logs show all supervised services.
* a Space restart does not lose project data.
* a sleeping Space cold-start is acceptable.
* normal rebuilds do not reinstall TeX Live.

## Step 15 — Operating model

Normal app changes should rebuild only:

* frontend;
* y-webrtc;
* PeerJS;
* FilePizza;
* Nginx config;
* Supervisor config;
* HF-specific settings.

They should not rebuild:

* `texlive-full`;
* Python TeX Live dependencies;
* gevent;
* kpathsea-related artifacts;
* TeX format files.

When TeX Live must change:

1. rebuild `ruthenian8/texlyre-texlive-ondemand-server`;
2. publish a new tag;
3. update the HF Space Dockerfile tag or digest;
4. redeploy the Space;
5. run the full smoke test again.

With `ruthenian8/texlyre-texlive-ondemand-server` already built and published, the Hugging Face plan becomes substantially simpler. The key remaining task is not compiling TeX Live; it is wiring the frontend and auxiliary services around the prebuilt TeX Live server through one Nginx-routed HF Space.
