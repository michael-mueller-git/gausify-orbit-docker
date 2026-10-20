# syntax=docker/dockerfile:1
# Self-contained Gausify Orbit: Brush WASM + web build + AI models baked in,
# served by nginx. No runtime requests to huggingface.co; fully offline once
# the page (and its service worker precache) is loaded.
#
#   docker build -t gausify-orbit .
#   docker run -p 8080:80 gausify-orbit

# ---------------------------------------------------------------- brush wasm --
FROM rust:1.99-slim AS brush

# Upstream gausify-orbit main as of 2026-10-20. The app sources, the
# build-brush-web.mjs script and the web/brush/*.patch files all live there;
# this wrapper repo only ships the Dockerfile, nginx.conf, the selfhost patch
# and model-urls.txt. Pin the rev: patches/model checksums are verified against it.
ARG GAUSIFY_REV=f019927d640b0f39c3687ccdee835ed459418538

# node is only needed to run scripts/build-brush-web.mjs (Node stdlib only).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && cargo install wasm-pack --locked

RUN git clone https://github.com/obraia/gausify-orbit.git /src \
 && git -C /src checkout -q "$GAUSIFY_REV"

WORKDIR /src

# Clones Brush at the pinned rev, applies web/brush/*.patch and outputs web/pkg/
RUN node scripts/build-brush-web.mjs

# ------------------------------------------------------------------ web build --
FROM node:24-slim AS web

WORKDIR /src
COPY --from=brush /src .
COPY patches/selfhost.patch /tmp/selfhost.patch

# Self-host patch: same-origin model URLs + hide the share UI (needs CF Workers).
RUN npm install -g pnpm@11 \
 && pnpm install --frozen-lockfile \
 && patch -p1 < patches/selfhost.patch \
 && pnpm web:build

# Bake the models next to the build output. Their SHA-256 is verified here
# (build fails on mismatch) and again by the app after download.
COPY model-urls.txt /tmp/model-urls.txt
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && while read -r dest url sha; do \
      echo "Fetching $dest"; \
      curl -fsSL --retry 5 --retry-delay 5 -o "/src/dist-web/$dest" "$url"; \
      echo "$sha  /src/dist-web/$dest" | sha256sum -c --quiet -; \
    done < /tmp/model-urls.txt

# --------------------------------------------------------------------- serve --
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web /src/dist-web /usr/share/nginx/html

EXPOSE 80
