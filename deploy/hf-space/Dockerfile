# syntax=docker/dockerfile:1

ARG TEXLIVE_BASE_IMAGE=ruthenian8/texlyre-texlive-ondemand-server:76f84c7

# ---- Stage 1: frontend build ----
FROM node:24-bookworm AS frontend-build

WORKDIR /src/frontend/texlyre

COPY frontend/texlyre/package*.json ./
RUN npm ci

COPY frontend/texlyre/ ./
COPY deploy/hf-space/texlyre.config.hf.ts ./texlyre.config.ts

RUN npm run generate:configs
RUN npm run build


# ---- Stage 2: y-webrtc ----
FROM node:24-bookworm AS ywebrtc-build

WORKDIR /src/y-webrtc-server

COPY services/y-webrtc-server/package*.json ./
RUN npm ci --omit=dev

COPY services/y-webrtc-server/ ./


# ---- Stage 3: PeerJS ----
FROM node:24-bookworm AS peerjs-build

WORKDIR /src/peerjs-server

COPY services/peerjs-server/package*.json ./
RUN npm ci

COPY services/peerjs-server/ ./
RUN npm run build
RUN npm ci --omit=dev


# ---- Stage 4: FilePizza ----
FROM node:24-bookworm AS filepizza-build

RUN corepack enable

WORKDIR /src/filepizza-server

COPY services/filepizza-server/package.json services/filepizza-server/pnpm-lock.yaml services/filepizza-server/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

COPY services/filepizza-server/ ./
RUN pnpm build


# ---- Stage 5: Node runtime source ----
FROM node:24-bookworm AS node-runtime


# ---- Final HF runtime image ----
FROM ${TEXLIVE_BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TEXLYRE_DATA_DIR=/data/texlyre

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    supervisor \
    redis-server \
    curl \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node

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
             /data/texlyre/logs /data/texlyre/artifacts /data/texlyre/cache \
 && chown -R user:user /app /tmp/nginx /tmp/redis /tmp/supervisor /app/run /data

USER user

ENV HOME=/home/user
ENV PATH=/home/user/.local/bin:/usr/local/bin:$PATH

EXPOSE 7860

CMD ["/entrypoint.sh"]
