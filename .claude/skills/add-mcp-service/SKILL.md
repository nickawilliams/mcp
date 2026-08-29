---
name: add-mcp-service
description: Add an MCP service to this repo from a reference to the upstream — npm package, git repo, docker image, website, or just a name. Checks it against the platform's hard requirements before any work starts, pausing if one fails. Use when asked to add, onboard, or wire up a new MCP server, or to judge whether one would fit here.
---

# Add an MCP service

The argument is a reference to the upstream: an npm package, a git repo, a
docker image, a website, or just a name. Resolve it to a concrete artifact
first — what is published decides most of what follows. If no argument was
given, ask which server to add rather than guessing.

**The build procedure is not here.** `README.md` § "Adding a service" is
canonical and stays that way; duplicating it guarantees drift. This skill
covers what the README does not: deciding whether a server *can* be added,
which of the platform's variants it needs, and the traps that cost real time
on the first three.

## Phase 1 — Evaluate before building

Work through this before touching a file. Each item has a decision attached,
and several can stop the job. **If any hard blocker fails, stop and ask the
user how to proceed** — do not improvise around it. Present what failed, the
options, and a recommendation.

### Hard requirements

1. **Transport.** Does it speak streamable HTTP?
   - *Native HTTP* → proxy straight to it (graphiti, ebay).
   - *stdio only* → wrap it with supergateway in-container (mail). Costs a
     `services/<name>/Dockerfile` and a `command:` block. Workable, not a
     blocker.
   - *SSE-only or pre-2025 protocol* → check what it actually negotiates.
     May need `--protocolVersion` pinned (mail pins `2025-03-26` because the
     bridge default `2024-11-05` is older than the server speaks).
   - *Neither* → **blocker**.

2. **linux/arm64.** The host is a single arm64 EC2 box.
   - *Upstream publishes arm64* → use it directly.
   - *No arm64 artifact* → we build and publish our own to ghcr, with a
     `publish/<name>-mcp` Makefile target and a thin workflow wrapper. Both
     mail and ebay do this; copy whichever is closer. Costs real setup.
   - *Cannot build for arm64* (native deps, prebuilt amd64 binaries) →
     **blocker**.

3. **Credentials, and whether they expire.**
   - *Static API key / password* → straight into the module's `secrets` map.
   - *OAuth user token that expires* → needs a re-mint path before it is
     worth adding. ebay's lives ~18 months, does not rotate on use, and needs
     `make maintenance/ebay-token` plus a 1Password item and a
     `services/<name>/README.md` documenting the reseed. Plan that work in.
   - *Interactive-only auth with no headless or long-lived path* →
     **blocker**; it will strand the service the first time it expires.

4. **Secret basename collisions.** `refresh.sh` flattens every service's
   secrets into one host `.env` using the last SSM path segment, so basenames
   must be unique across **all** services, not just within the new one. Check
   the existing `secrets` / `generated_secrets` keys in
   `terraform/services.tf`. A collision is not fatal but must be resolved by
   renaming before you write anything.

5. **Entity budget.** Each service costs one Auth0 resource server and one
   application slot's worth of headroom. Free tier caps both at 10;
   self-service (Essentials) at 100. Check the current count before adding —
   `make maintenance/gc GC=--dry-run`, run from `~/Projects/infrastructure`,
   clears DCR debris and reports what is left. If adding this service would
   crowd the cap, say so before building.

6. **What the code gets to reach.** This is third-party code that will
   receive a bearer token on every call and run on the same host as mail
   (every email account) and graphiti (the whole memory graph). Per-service
   audiences mean a compromised service's token is only good for itself — but
   check what the upstream actually does: outbound network, filesystem, any
   credential broader than the service needs. If it wants access
   disproportionate to its job, raise it. This is the failure mode with the
   highest probability in this design; see ROADMAP's Stytch verdict.

### Shape decisions (not blockers, but decide now)

7. **MCP path** → picks the Caddy proxy snippet.
   - Serves under `/mcp` → `mcp_proxy_subpath`.
   - Serves at `/` and 400s dead sessions → `mcp_proxy_root_sessions`.
   - Neither → a new snippet, which is a deliberate addition, not a default.

8. **Sessions.** Prefer stateless if the server tolerates it. mail runs the
   bridge stateless because stateful session reaping killed sessions
   mid-conversation: clients holding no GET/SSE stream drop the access count
   to zero after each response, so the idle timer restarted from every tool
   call. A server that declares tools-only capabilities and derives ids from
   stable upstream state (IMAP UIDVALIDITY/UID) loses nothing by it.

9. **Persistent state.** If it needs a data dir, it goes in the
   `mkdir -p data/...` line in `scripts/refresh.sh`.

10. **Bespoke terraform.** Only if it needs a resource the shared module has
    no notion of — an upstream SaaS credential with its own provider. Most
    services need none; `graphiti.tf` is the only example.

## Phase 2 — Build

Follow `README.md` § "Adding a service", steps 1–7, with the Phase 1
decisions in hand. Copy the closest existing service as scaffold:

- **graphiti** — native HTTP, `/mcp` subpath, plus a dependent datastore with
  a healthcheck and `depends_on`.
- **mail** — stdio upstream behind a supergateway bridge, self-published
  arm64 image, stateless, per-account secret fan-out.
- **ebay** — native HTTP at root with session handling, self-published image
  from a git ref, expiring OAuth user token.

## Phase 3 — Verify

- `make plan` and read it: expect a DNS record, a bearer token param, an
  `auth0_resource_server`, an `auth0_client_grant`, and one SSM param per
  secret. Anything else means something is in the wrong layer.
- `make apply`, then commit, push, `make deploy`. Unpushed work never
  deploys; `make apply` alone does not move files.
- `curl https://<name>.mcp.nickawilliams.com/` → **401** with a
  `WWW-Authenticate` header pointing at the metadata document.
- `curl .../.well-known/oauth-protected-resource` → `resource` must be the
  slashed form and byte-identical to the terraform identifier.
- Connect a real client and confirm the tool list.

## Traps

Each of these cost time already. They are not obvious from the code.

- **The trailing slash on the Auth0 identifier is load-bearing**, and
  resource server identifiers are **immutable**. Get it right the first time
  or the service runs two of them until one is withdrawn. Claude Code
  normalizes via the WHATWG URL API and always sends the slash; claude.ai
  takes its audience from the RFC 9728 metadata Caddy serves.
- **Icons must be committed.** `make icons` runs in docker locally; the host
  has no toolchain and only serves what git delivered. The logo must be the
  mark alone in a single brand hex — a colourless glyph fails the run.
- **Compose relative paths are from `/opt/mcp`**, not from the file's own
  directory, because the root compose sets `project_directory`.
- **Mount directories, not files.** `refresh.sh` replaces files with `mv`,
  and a single-file bind mount pins the old inode forever.
- **Bind ports to `127.0.0.1` only.** The sole public surface is Caddy `:443`.
- **Each service gets its own compose network**, with only Caddy attached to
  all of them, so one service cannot reach another's backend directly. Note
  this does not stop a compromised service calling another through the public
  front door — that is what per-service audiences are for.
- **Some upstreams reject a non-localhost Host** (the MCP SDK's DNS-rebinding
  guard). `mcp_proxy_subpath` already sends `header_up Host localhost:<port>`.
- **A client that cannot authorize is usually unregistered, not broken.**
  `403 limit of entities` is the DCR cap; an "Unknown client" is a CIMD URL
  missing from terraform. See AGENTS.md § "Auth failures".
