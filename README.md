# gausify-orbit-docker

Self-contained Docker image of [obraia/gausify-orbit](https://github.com/obraia/gausify-orbit):
web UI, Brush training WASM, and all AI models baked in — no requests to
huggingface.co at runtime, works offline (the app's service worker precaches
the whole build on first load, and models are served same-origin).

## Build

```sh
docker build -t gausify-orbit .
```

Build stages:

1. **brush** — `rust:1.99-slim` + `wasm-pack`, runs `pnpm web:wasm`
   (clones Brush at the pinned rev, applies `web/brush/*.patch`, emits `web/pkg/`).
2. **web** — `node:24-slim`, applies `patches/selfhost.patch`, runs `pnpm web:build`,
   then downloads the 9 ONNX models from `model-urls.txt` into `dist-web/models/`
   and verifies each SHA-256 (build fails on mismatch; the app re-verifies after download).
3. **serve** — `nginx:1.27-alpine` with `nginx.conf`
   (COOP/COEP headers for WebGPU/WASM threads, gzip, `.wasm` MIME type).

## Run

```sh
docker run -p 8080:80 gausify-orbit
# open http://localhost:8080
```

## Image contents / sizes

| Model | Files | Size |
|---|---|---|
| RMBG-1.4 (`models/rmbg14.onnx`) | 1 | ~176 MB |
| SAM 2.1 tiny fp32 (`models/sam2-fp32/`) | 4 | ~165 MB |
| SAM 2.1 tiny fp16 (`models/sam2-fp16/`) | 4 | ~84 MB |

## CI

`.github/workflows/docker.yml` (modeled on
[michael-mueller-git/anysplat-docker](https://github.com/michael-mueller-git/anysplat-docker))
builds and pushes to `ghcr.io/<owner>/<repo>` on pushes to `main`, tags and
`workflow_dispatch`, with GHA layer caching (the Brush build is the slow part).

## Notes

- `patches/selfhost.patch` also removes the share button — share links are
  stored in Cloudflare KV (`worker/`) and only work on the Cloudflare deployment.
- First run needs a WebGPU-capable browser (Chrome/Edge ≥ 113); the models are
  fetched once into the browser's OPFS cache, after which the client is offline too.
- On Linux, Chromium may need Vulkan enabled to expose WebGPU (and hardware
  acceleration can require extra flags depending on GPU/driver):

  ```sh
  chromium --enable-features=Vulkan
  # if the GPU/driver is not on Chrome's whitelist, also try:
  chromium --enable-features=Vulkan --enable-unsafe-webgpu
  ```

  Verify at `chrome://gpu` that "WebGPU" shows up as available.
