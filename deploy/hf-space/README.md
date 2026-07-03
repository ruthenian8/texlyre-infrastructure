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

# TeXlyre Hugging Face Docker Space

This directory is the single-container Hugging Face Docker Space deployment target for TeXlyre.

For the actual Space repository, copy or mirror this directory so that `Dockerfile`, `README.md`, `.dockerignore`, and the other deployment files are at the Space repository root.

## Runtime Layout

Nginx listens on port `7860` and routes:

- `/texlyre/` to the static TeXlyre frontend
- `/api/texlive/` to the TeX Live on-demand server from the base image
- `/ywebrtc/` to y-webrtc signaling
- `/peerjs/` to PeerJS signaling
- `/filepizza/` to FilePizza

Supervisor starts Nginx, Redis, the TeX Live server, y-webrtc, PeerJS, and FilePizza inside one container. Redis is bound to `127.0.0.1:6380` and is intentionally ephemeral.

## Required Preflight

Before building this image for deployment:

1. Inspect `ruthenian8/texlyre-texlive-ondemand-server:76f84c7` and confirm the TeX Live server app directory.
2. Update `[program:texlive-server] directory=` in `supervisord.conf` if the server is not stored in `/app`.
3. Replace `REPLACE_WITH_SPACE_SUBDOMAIN` in `texlyre.config.hf.ts` with the final Hugging Face Space subdomain.

The expected TeX Live server command is:

```bash
python3 wsgi.py
```

Do not add `apt-get install texlive-full` to this Dockerfile. TeX Live is supplied by the published base image.

## Local Smoke Test

After the preflight values are replaced and submodules are initialized:

```bash
docker build -f deploy/hf-space/Dockerfile -t texlyre-hf-space .
docker run --rm -p 7860:7860 texlyre-hf-space
curl http://localhost:7860/health
```

Then open:

```text
http://localhost:7860/texlyre/
```

Check that:

- `/health` returns `200`
- `/` redirects to `/texlyre/`
- the frontend loads without CORS or mixed-content errors
- the TeX Live endpoint responds through `/api/texlive/`
- y-webrtc upgrades through `/ywebrtc/`
- PeerJS responds through `/peerjs/`
- FilePizza loads through `/filepizza/`
- Supervisor logs show all services staying up

## Persistence

This deployment does not use Hugging Face persistent storage for TeX Live. The TeX Live tree is baked into `ruthenian8/texlyre-texlive-ondemand-server`.

To persist operational artifacts across cold starts, attach a Hugging Face Storage Bucket to the Space as a read-write volume at:

```text
/data
```

The image creates and uses these bucket-ready paths:

- `/data/texlyre/logs`
- `/data/texlyre/artifacts`
- `/data/texlyre/cache`

If no bucket is attached, the same paths exist inside the ephemeral container filesystem.

Runtime state that remains ephemeral:

- Redis
- y-webrtc state
- FilePizza sessions
- TeX Live packages and runtime tree

User projects should remain browser-local plus Git sync, not application-critical state in the Space filesystem.

To verify bucket persistence, create a marker file under `/data/texlyre/artifacts`, restart or cold-start the Space, and confirm the marker still exists. Redis and collaboration/session state should not intentionally survive the restart.
