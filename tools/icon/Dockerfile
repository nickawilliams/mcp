# Throwaway build image for the icon generator (`make icons`). The generator
# needs a Node toolchain and a rasteriser, and nothing else in this repo does —
# keeping both in an image means no local toolchain, no committed node_modules,
# and the same behaviour locally and in CI. Docker is already a hard
# requirement here (the publish/* targets).
#
# node:22-slim (glibc), not alpine: @resvg/resvg-js ships its rasteriser as a
# per-platform native optional dependency, and the glibc builds are the
# best-covered ones.
FROM node:22-slim

WORKDIR /icon

# Manifest first so the install layer caches across edits to the script itself.
# It exists only to pin the rasteriser; the script's .mjs extension already
# makes it ESM, so the "type": "module" alongside is belt-and-braces.
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# logo.svg is the MCP watermark, read from disk at startup — it must sit beside
# the script, which resolves it relative to its own location.
COPY generate.mjs logo.svg ./

ENTRYPOINT ["node", "/icon/generate.mjs"]
