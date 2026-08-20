# ebay-mcp (YosefHayim/ebay-mcp): TypeScript MCP server for eBay's Sell
# APIs, published to npm. Pure JS — no arm64 publish pipeline needed (cf.
# services/mail); the image is assembly only: pinned runtime + pinned
# package. Node 22 (LTS): the package needs >=20, but 20 hit EOL 2026-04.
# The HTTP entrypoint (build/serverHttp.js) is a native streamable-HTTP
# server, so no supergateway bridge either. It persists refreshed eBay
# tokens to the package root's .env (best-effort — failures degrade to
# in-memory, and the durable refresh token is env-seeded from SSM), so the
# write lands in the ephemeral container layer by design.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32

RUN npm install -g ebay-mcp@1.15.0

CMD ["node", "/usr/local/lib/node_modules/ebay-mcp/build/serverHttp.js"]
