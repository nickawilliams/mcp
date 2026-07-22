# Roadmap

A living design document for **v2** of the MCP platform. v1 (this repo) is a
single arm64 EC2 host running docker-compose behind Caddy: TLS, host-per-service
routing, static-bearer auth, one service (graphiti). It works and is deliberately
simple.

This file captures the **limitations we actually hit** and the v2 solutions we'd
want, so that when the fleet and the needs have grown enough, v2 is an
iteratively-refined, evidence-backed shape rather than a speculative rewrite.

## How to use this doc

When v1 can't cleanly solve something and we decide we'd want it later, add a
candidate entry below using the template. Don't build ahead of need — accumulate.
When several entries share a **trigger** and a mechanism, that clustering is the
signal that it's time to build v2 (or the relevant slice of it).

```
### Cx — <title>
- **Need**:                what we want, and why
- **v1 limitation**:       why v1 can't do it cleanly (with evidence/date)
- **Candidate v2 mechanism**: how v2 would solve it
- **Trigger to build**:    the condition that makes it worth doing
- **Caveats**:             honest downsides / things it doesn't solve
- **Interim (v1) mitigation**: what we do until then
- *Logged: YYYY-MM-DD*
```

---

## Emerging v2 hypothesis: an MCP-aware gateway behind Caddy

The through-line of most entries below: v1's front door (Caddy) is **MCP-blind** —
it operates at HTTP and treats the JSON-RPC payload as opaque bytes. That's why it
can't touch anything *inside* the protocol (the `instructions` field, `group_id`
in tool calls, tool lists). Several accumulating needs all require the same thing:
a layer that **parses the MCP protocol**.

Proposed topology (additive, not a teardown):

```
client ──TLS──> Caddy (edge: TLS, host routing, coarse auth)
                  └──> MCP gateway (protocol-aware: instructions, group
                        enforcement, aggregation, tool policy, audit)
                          └──> graphiti  (+ future MCP backends)
```

Caddy keeps the battle-tested edge (ACM-free wildcard, host routing); the gateway
adds MCP intelligence; backends are unchanged. It composes with the existing
`services` map (each service is a backend the gateway fronts).

**Candidate products to evaluate when the time comes** (young, churning category —
capabilities vary widely, verify per-feature before committing): agentgateway,
IBM ContextForge (mcp-context-forge), MintMCP, Gravitee, Solo/kgateway, Docker MCP
Gateway, FastMCP proxy mode.

**Overall trigger for v2**: the arrival of **service #2–#3**, OR a concrete need
for **enforced** namespace isolation, tool **aggregation**, or centralized MCP
policy. Any one of those makes the gateway earn its complexity; today (one service,
one advisory want) it would be a cannon for a fly.

**Repo decision (2026-07-21)**: whichever way build-vs-buy goes, the gateway
does **not** live in this repo — it arrives as an external image dependency
(see C6). This repo stays pure composition: images, config, IaC.

---

## Candidate capabilities

### C1 — Directive server-provided instructions (make memory get *used*)
- **Need**: MCP tools are inert — being connected ≠ being used. To behave as
  long-term memory, some layer must tell every client to proactively recall before
  answering and persist durable facts. Ideally one place, all clients.
- **v1 limitation**: graphiti's `instructions` string is a hardcoded module
  constant (`GRAPHITI_MCP_INSTRUCTIONS`, passed to `FastMCP(instructions=...)`),
  with no config or env binding — not overridable via our rendered `config.yaml`
  (verified against getzep/graphiti mcp_server v1.0.2, 2026-07-20). Caddy can't
  inject it either (MCP-blind; would mean rewriting streamed initialize response
  bodies — the rabbit hole).
- **Candidate v2 mechanism**: MCP gateway augments/overrides the `instructions`
  field in the initialize response — one directive, delivered to every client and
  every backend.
- **Trigger to build**: bundled with the gateway (C0/hypothesis) — not worth a
  fork on its own.
- **Caveats**: server instructions are **advisory** — models weight their own
  instruction layer (CLAUDE.md / rules) higher. The gateway fixes universal
  *delivery*, not *authority*, so it's a floor under client-side rules, not a
  replacement.
- **Interim (v1) mitigation**: a single canonical directive block managed
  client-side — full version in Claude Code `CLAUDE.md`, pasted verbatim into the
  1–3 other clients actually used (Codex `AGENTS.md`, Cursor rules, Desktop custom
  instructions). Stable text, bounded fan-out. (A graphiti overlay image that
  regex-patches the constant is possible but rejected: silent-revert risk on
  upstream reword + advisory payoff.)
- *Logged: 2026-07-20*

### C2 — Enforced namespace isolation (personal / work, and beyond)
- **Need**: a hard boundary between memory domains so a work session cannot read
  or corrupt personal memory (and vice versa), ideally client-selectable.
- **v1 limitation**: a pinned `GRAPHITI_GROUP_ID` is only a **default**, not a
  boundary — every tool resolves `group_id or config.group_id`, so a client can
  pass any `group_id`/`group_ids` and reach/modify/clear another group; deletes take
  a bare UUID with no group scope at all. FalkorDB keys the physical graph by the
  `database` value, not by group_id (groups are a property filter within one graph).
  So pinning group_id gives soft isolation only (verified in graphiti source,
  2026-07-20).
- **Candidate v2 mechanism**: MCP gateway maps **token → group** and *clamps/injects*
  `group_id` on every call (rejecting client overrides) — enforced isolation on a
  single graphiti instance, no per-domain container needed.
- **Trigger to build**: wanting real personal/work (or per-project) separation on
  shared infra.
- **Caveats**: gateway-enforced clamp is "enforced soft" — still one shared graph.
  True storage isolation (separate `FALKORDB_DATABASE`, or separate FalkorDB) remains
  the gold standard; the gateway is the cheaper 90%.
- **Interim (v1) mitigation**: (a) accept soft isolation and rely on instruction
  discipline; or (b) two graphiti containers each pinning a distinct
  `FALKORDB_DATABASE` + own subdomain + own token — hard isolation via the existing
  `services` map, ~30–45 min, at the cost of a second server process on the box.
  Migrating today's `main` group into a named domain later is cheap (one Cypher pass,
  or just inherit it as "personal").
- *Logged: 2026-07-20*

### C3 — Tool aggregation (one endpoint, many services)
- **Need**: a client connects once and sees the union of tools across all MCP
  services, instead of configuring N endpoints.
- **v1 limitation**: v1 is deliberately host-per-service (`<svc>.mcp.…`); no
  aggregation layer exists.
- **Candidate v2 mechanism**: MCP gateway fans out to multiple backends and
  presents a merged tool list / routes calls by tool namespace.
- **Trigger to build**: service #2+ where a single client wants both.
- **Caveats**: tool-name collisions across services need a namespacing scheme;
  aggregation can obscure per-service auth/rate boundaries — decide what stays
  per-service.
- **Interim (v1) mitigation**: configure each service as its own MCP entry in the
  client (host-per-service already makes this clean).
- *Logged: 2026-07-20*

### C4 — Universal client auth (OAuth alongside bearer)
- **Need**: support the OAuth-only clients (claude.ai web connectors for individual
  accounts, ChatGPT) in addition to the header-capable dev tools.
- **v1 limitation**: a single endpoint can't cleanly serve both — if it advertises
  OAuth, Claude Code and Cursor ignore the configured static header and force OAuth
  discovery (live client bug; Claude Code #59467 / Cursor forum #156054,
  still-broken as of ~May 2026 — **re-verify before acting**, fast-moving). So v1
  deliberately serves *no* OAuth metadata (bearer only).
- **Candidate v2 mechanism**: near-term — a **second hostname** (`<svc>-oauth.mcp.…`)
  with a managed IdP (WorkOS AuthKit / Auth0 / …) as authorization server and
  Caddy/graphiti as resource server; per-hostname isolation keeps the OAuth host
  from poisoning the bearer host. End-state — a **single universal endpoint** that
  offers bearer *and* OAuth once the client header-override bug is fixed.
- **Trigger to build**: wanting graphiti as a claude.ai-web or ChatGPT connector.
- **Caveats**: OAuth is hostile to headless/automation contexts (needs a browser);
  the bearer path must stay for scripts/CI. This is largely independent of the MCP
  gateway (it's a Caddy + IdP concern), so it can land on its own timeline.
- **Interim (v1) mitigation**: bearer covers 100% of clients actually run on your
  own machines; the two web connectors simply aren't wired up.
- *Logged: 2026-07-20*

### C5 — Cross-client behavior management
- **Need**: consistent memory (and future tool-use) behavior across Claude Code,
  Codex, Cursor, Windsurf, Desktop — without hand-maintaining it in each.
- **v1 limitation**: there's no universal client-side instruction layer; each
  client injects standing instructions through its own surface (`CLAUDE.md`,
  `AGENTS.md`, Cursor rules, Desktop custom instructions). McpOne (and similar)
  manage the *connection* config fan-out but not the *instruction* fan-out.
- **Candidate v2 mechanism**: mostly subsumed by C1 (directive server instructions
  as the cross-client floor); the gateway is the only shared layer that reaches all
  clients at once.
- **Trigger to build**: driving ≥3 clients where drift becomes a real cost.
- **Caveats**: same advisory-strength ceiling as C1.
- **Interim (v1) mitigation**: one canonical rules snippet, fanned out via dotfiles
  symlink or McpOne-if-it-grows-that-feature; stable text, so low churn.
- *Logged: 2026-07-20*

### C6 — Gateway as an external image dependency (own repo)
- **Need**: a home for the (possibly custom, Go) gateway codebase and a
  delivery path for its artifact, without reshaping this repo.
- **v1 limitation**: this repo builds no software — delivery is small text
  files via SSM params (4–8 KB caps); it cannot carry a codebase, and on-host
  source builds are undesirable (2026-07-21).
- **Candidate v2 mechanism**: the gateway lives in its own repo with its own
  CI/releases, publishing a container image; this repo consumes it as a
  pinned image reference (digest/version tag, never `:latest` — see the
  graphiti pin item below) plus a terraform-rendered config template. Same
  contract as Caddy today: **the image is theirs, the config instance is
  ours** (tokens, group maps, backend routes are platform data). Symmetric
  with build-vs-buy — an off-the-shelf gateway product slots in identically,
  and the choice can change later without restructuring this repo.
- **Trigger to build**: the decision to run a gateway at all (the overall v2
  trigger above).
- **Caveats**: cross-repo friction while the gateway's config schema churns
  against the platform (coupled changes = two PRs + a version bump; mitigate
  with a local compose override pointing at a locally built image). A
  **private** image adds a platform prerequisite: registry pull auth on the
  host (ECR role grant or GHCR token); a public image needs nothing.
- **Interim (v1) mitigation**: none needed — nothing in this repo changes
  until a gateway exists.
- *Logged: 2026-07-21*

---

## Open questions

- **File memory vs graphiti division of labor.** `~/.claude/…/memory/MEMORY.md`
  (local, always-in-context, hand-curated) vs graphiti (cross-client, on-demand,
  auto-extracted). Unresolved: which facts live where, and whether rules should
  forbid duplicating a fact into both. Drives the wording of the C1/C5 client block.
- **Is "enforced soft" (gateway group clamp) enough for personal/work**, or is
  storage separation (`FALKORDB_DATABASE`) required? Depends on how sensitive work
  memory is and whether it should even live on personal AWS infra at all.
- **Which gateway product** — needs a real capability survey focused on
  instructions-injection + group-enforcement + aggregation before v2 commits.

---

## Near-term backlog (v1 hardening — not v2)

Small operational gaps to close within v1, independent of the v2 vision:

- ~~**Implement `make deploy`**~~ — done 2026-07-21: `refresh.sh` (rendered,
  SSM-delivered) pulls all config/secrets by path and reconciles compose; both
  cloud-init and `make deploy` run it, so first boot and config pushes are one
  mechanism.
- ~~**Token-rotation runbook**~~ — done 2026-07-21 (per-service tokens landed
  with the services/ restructure):
  `terraform apply -replace='module.<name>.random_password.bearer'` →
  `make deploy` → update that service's clients
  (`terraform output -json service_bearer_tokens`). Other services unaffected.
- **Pin the graphiti image to a digest** — currently rides mutable
  `zepai/knowledge-graph-mcp:standalone`. The silent-drift risk is real: upstream has
  reworded the instructions constant and uses nested env binding
  (`GRAPHITI__GROUP_ID`); a schema/behavior change on pull could quietly land writes
  in the wrong namespace. Pin + eyeball the startup log (`Using group_id`,
  `Using database`) after any deliberate bump.
- **Retire the stale claude.ai `Graphiti[id=…]` connector** (web UI) — throws
  `-32000` reconnect noise and embeds the token in its command line.
