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
ARG GAUSIFY_REV=e6c99553ddc12bc1a37c0ee362ab5f489bb7a926

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
COPY patches/ /tmp/patches/

# node:24-slim ships neither patch nor git; only patch is needed to apply the
# patches. pnpm is pinned to packageManager in package.json.
RUN apt-get update \
 && apt-get install -y --no-install-recommends patch \
 && rm -rf /var/lib/apt/lists/*

# Self-host patch: same-origin model URLs + hide the share UI (needs CF Workers).
# Vite patch: keep the modulepreload polyfill out of ONNX Runtime's workers.
RUN npm install -g pnpm@11.20.0 \
 && pnpm install --frozen-lockfile \
 && patch --batch -p1 < /tmp/patches/vite-ort-worker.patch \
 && patch --batch -p1 < /tmp/patches/selfhost.patch \
 && pnpm web:build

# Bake the models next to the build output. Their SHA-256 is verified here
# (build fails on mismatch) and again by the app after download.
COPY model-urls.txt /tmp/model-urls.txt
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    while read -r dest url sha; do \
      case "$dest" in ''|'#'*) continue ;; esac; \
      mkdir -p "/src/dist-web/$(dirname "$dest")"; \
      echo "Fetching $dest"; \
      curl -fsSL --retry 5 --retry-delay 5 -o "/src/dist-web/$dest" "$url"; \
      echo "$sha  /src/dist-web/$dest" | sha256sum -c --quiet -; \
    done < /tmp/model-urls.txt

# --------------------------------------------------------------------- serve --
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web /src/dist-web /usr/share/nginx/html

EXPOSE 80
