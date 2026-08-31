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
*Update 2026-07-22: service #2 (mail) landed — the trigger is partially met.
One more service, or any enforcement need, tips it.*

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
  every backend. Branding rides the same mechanism for free: inject
  `serverInfo.icons` / `websiteUrl` (SEP-973, spec 2025-11-25) so connectors get
  per-service icons without upstream support — pointless until clients render
  the field (claude.ai and Claude Code show a generic globe regardless as of
  2026-08; claude-ai-mcp#152, claude-code#44675), so check client support at
  gateway time.
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

### C4 — Universal client auth (OAuth alongside bearer) — **LANDED 2026-08-07**
- **Landed**: dual-path auth live on every vhost (commit `ccb2684`). Identity
  (Auth0 tenant, DCR flag, `auth.nickawilliams.com` custom domain) lives in the
  infrastructure repo; this repo registers per-service audiences + default
  third-party grants and validates JWTs offline at Caddy (caddy-jwt, JWKS).
  End-to-end verified in production: DCR → PKCE → custom-domain-issued at+jwt
  → 31 mail tools; audience isolation confirmed (mail-audience token 401s at
  graphiti); static-bearer path regression-clean. The interim 404 scaffolding
  is removed. Remaining (client-side, not platform): migrate client configs
  to plain URLs and retire the mcp-remote shims.
- **Provider re-evaluation (2026-08-09)**, triggered by ChatGPT's DCR hitting
  the free plan's **10-Application entity cap** (each DCR registration mints a
  permanent `tpc_*` client; interrupted flows leave debris). Alternatives
  weighed and rejected: WorkOS AuthKit (best MCP feature set, but custom
  domains — the property that keeps our `auth.nickawilliams.com` issuer
  portable — are a $99/mo add-on); Keycloak (no RFC 8707 — audience isolation
  would ride on scope workarounds — and its JVM exceeds the t4g.small's free
  headroom); other OSS (no credible MCP RFC coverage; all self-host options
  make us the patch-response team for mail's front door). **Decision: stay on
  Auth0 free** with (a) `make gc` (scripts/auth0-gc.sh) deleting
  never-authorized DCR debris — zero user grants + no recent log activity,
  least-privilege `auth0-client-mcp-gc` credential; (b) CIMD enabled on the
  tenant (`client_id_metadata_document_supported`, advertised in AS metadata).
  CIMD is the MCP spec's SHOULD-level registration mechanism (2025-11-25
  revision; DCR demoted to MAY): URL-identified clients register once per
  deployment, not per machine, so cap pressure decays as clients adopt it.
  Escape hatches if the cap bites first: Essentials ($35/mo, 100 apps), or a
  provider switch kept cheap by the custom-domain issuer.
- **CIMD correction (2026-08-11)**: Auth0's CIMD is *admin-registered, not
  just-in-time* — the tenant flag only advertises support; each metadata URL
  must be registered before `/authorize` accepts it, else
  `invalid_request: Unknown client: <url>` (which broke Claude Code reauth for
  ~2 days; CIMD-capable clients prefer CIMD over DCR the moment it is
  advertised, and fail hard). Registrations are now terraform-managed in the
  infrastructure repo's identity module (`auth0_client_cimd` per URL, provider
  ≥1.44; tenant flag codified there too) — onboarding a new CIMD client is a
  one-line `cimd_clients` entry when its "Unknown client" rejection shows up
  in tenant logs. Auth0 has API plumbing for client self-registration
  (`external_metadata_created_by: client`) but no shipped feature yet —
  revisit if it lands, it would eliminate the per-client entry. Gotcha fixed
  in the same pass: CIMD clients get `tpc_*` internal ids like DCR debris, so
  `auth0-gc.sh` now keys on `external_metadata_type == "dcr"` instead of the
  prefix (a fresh CIMD registration has zero grants and looked collectable).
- **DCR vs CIMD — which limit bites, and whose fault (added 2026-08-24)**:
  the two registration mechanisms fail in different ways, and confusing them
  costs a debugging cycle every time. Both mint a `tpc_*` application, so
  **both count against the same 10-app free-plan cap** — CIMD's win is not
  bypassing the cap but that entries accrue per client *app* instead of per
  *machine*, so pressure stops scaling with device count.

  | | DCR (RFC 7591) | CIMD (metadata-document client IDs) |
  |---|---|---|
  | How a client registers | Self-registers at `/oidc/register`, just-in-time, once per install/machine | Its metadata URL *is* the `client_id`; must be pre-registered in terraform `cimd_clients`, once per client app |
  | Limit you hit | 10-application cap → `403 limit of entities`; interrupted flows leave debris | `invalid_request: Unknown client: <url>` until the entry exists |
  | Diagnose with | `make maintenance/gc GC=--dry-run` | `make maintenance/cimd-pending` |
  | Where from | `~/Projects/infrastructure` (moved there 2026-08-27) | same |
  | Whose limitation | **Auth0** — mints a permanent app per registration, caps apps at 10 | **Auth0** — advertises CIMD but ships no just-in-time acceptance |

  The switch is one-way: `client_id_metadata_document_supported` makes capable
  clients skip DCR entirely, with no fallback and a hard fail. Enabling CIMD
  *replaces* a working path rather than adding one, so every CIMD-capable
  client breaks until its URL is registered.

  One client-side exception to "once per client app": **ChatGPT mints a
  per-connector metadata URL** (`https://chatgpt.com/oauth/<id>/client.json`,
  where `<id>` also appears in its `redirect_uris` as
  `https://chatgpt.com/connector/oauth/<id>`), so for ChatGPT the rule
  degrades to once per *connector* — deleting and re-adding a connector
  burns another `cimd_clients` entry and another app slot. That is OpenAI's
  behavior, not Auth0's; claude.ai and Claude Code use stable app-level URLs
  and behave as documented. Observed 2026-08-24 when the ChatGPT app install
  failed with `Unknown client`; confirmed 2026-08-31 when adding a Graphiti
  connector minted a second, distinct metadata URL.

  **When Auth0 ships just-in-time CIMD, do not read it as pure good news.**
  CIMD changes the *unit* of cap growth (per client app instead of per
  machine); it does not raise the ceiling, because every CIMD registration
  still mints an application entity and the cap counts entities. Today the
  admin gate incidentally protects the cap: an unregistered URL fails at
  `/authorize` and consumes nothing, so a slot is spent only by an explicit
  `cimd_clients` entry. Just-in-time removes that gate — any CIMD client that
  appears mints its own app, which is DCR's failure mode again, merely bounded
  by distinct URLs instead of distinct installs. The loud, actionable
  "Unknown client" becomes silent slot consumption until `403 limit of
  entities`. That the entity survives is implied by the field name itself:
  `external_metadata_created_by: client` is an attribute *on the client
  entity*, so the entity persists and only its creator changes. Two
  consequences to handle in the same pass if it lands: (a) `auth0-gc.sh` goes
  stale again — its `external_metadata_type == "dcr"` filter would need to
  also reap *client-created* CIMD clients while sparing terraform-created
  ones, i.e. key on `external_metadata_created_by`; (b) ChatGPT becomes the
  worst case, since per-connector URLs plus automatic minting means connector
  churn silently eats slots. Nothing about CIMD raises the ceiling — only
  Essentials ($35/mo, 100 apps) or a provider switch does, per the 2026-08-09
  evaluation above.
- **Stytch evaluation (2026-08-24)**: the 2026-08-09 provider re-evaluation
  weighed WorkOS AuthKit, Keycloak, and generic OSS; Stytch was never
  considered, because that pass was framed around DCR, custom domains, and
  RFC 8707 rather than around CIMD statelessness — the criterion that
  actually bites. Assessed against the three questions that killed the
  earlier candidates:
  - **CIMD entity model** — Stytch fetches and validates the metadata
    document *during authorization* and refreshes it periodically, rather
    than pre-storing a client record; its docs contrast this explicitly with
    dashboard/API-created clients, which are "stored as persistent records."
    No client quota is documented. Its DCR also deduplicates public clients
    by hashing the submitted metadata, returning the existing client_id
    instead of minting a second — which would have prevented our debris
    problem outright. This is the one axis where Stytch is structurally
    better than Auth0, not merely cheaper. Caveat: CIMD is Beta there.
  - **RFC 8707** — supported, and documented specifically for MCP: the
    `resource` parameter is required at both authorize and token, and lands
    in the token's audience claim. This is what disqualified Keycloak, so
    the per-service `audience_whitelist` model in the Caddyfile would
    survive a move.
  - **Custom domain** — supported and **free**, confirmed 2026-08-24 from a
    real Stytch workspace rather than the docs (which omit pricing). Only
    custom *email sender* domains are gated to paid tiers, which we do not
    need — Auth0 sends no mail for us either. It sets the JWT `iss` to the
    custom domain, so `auth.nickawilliams.com` stays portable. This was the
    decisive question, since the equivalent $99/mo gate is what
    disqualified WorkOS; Stytch clears it. Free tier is 10k MAU.

  **Verdict: Stytch clears all three criteria** — the first candidate to do
  so, where WorkOS failed on cost and Keycloak on RFC 8707. Not migrating
  yet, for reasons that are now about risk rather than fit: their CIMD is
  Beta, the cap is not currently blocking (8 of 10 apps, GC script working),
  and moving an issuer that three client families hold live grants against
  forces a re-consent across every one of them.

  **Next step is a spike, not a migration.** Stand one service up against
  Stytch in parallel and verify by observation, not documentation. This
  entire thread began with Auth0's docs advertising CIMD while the
  implementation quietly required admin registration; the spike exists to
  catch that class of gap before a migration depends on it. Escalate to a
  real migration if the cap blocks a registration, if Auth0 ships JiT CIMD
  without fixing entity materialization (see the note above), or if
  ChatGPT's per-connector behavior turns out to be per *user*.

  *Run it before the next batch of services, not after.* Re-consent cost
  scales with service count, and the resource-server and client-grant counts
  it would move scale with it too — the spike is cheapest to act on while
  there are three services, not six.

  **Setup.** Nothing touches production identity: use a separate Stytch
  custom domain (`auth-spike.nickawilliams.com`, *not*
  `auth.nickawilliams.com` — that issuer holds live grants across three
  client families, and repointing it is the re-consent event this whole plan
  defers). Give the spike its own `spike.mcp.nickawilliams.com` vhost, which
  the wildcard cert already covers, fronting any existing backend or the
  2026-08-07 probe server. Keep it out of terraform and out of
  `modules/service`: that module hardcodes `auth0_resource_server`, and
  `mcp_jwt_gate` in the Caddyfile hardcodes the Auth0 JWKS and issuer, so
  the spike gets a throwaway copy of the snippet rather than a
  parameterization that would outlive its usefulness.

  **(a) CIMD accrues no persistent client entity.** The load-bearing claim,
  and the only axis where Stytch is structurally better rather than merely
  cheaper.
  - Record the workspace's client/connected-app count before anything
    authorizes.
  - Authorize a headerless Claude Code against the spike host, then re-check.
    Pass = unchanged.
  - Repeat with a second distinct client family (claude.ai connector) — a
    count that holds for one client but not two is dedup, not statelessness.
  - Separately confirm the documented DCR dedup: submit identical public
    client metadata twice, expect the same `client_id` back rather than a
    second app.
  - Fail signal: any counter increments per authorization. Stytch then has
    Auth0's materialization problem and the rationale for moving collapses —
    record that and stop.

  **(b) RFC 8707 round-trip yields the audience Caddy expects.**
  - Decode the access token; assert `aud` is exactly the resource identifier
    the vhost whitelists, not the `client_id` and not an array carrying
    extras.
  - Assert `iss` is the custom domain, not the Stytch-hosted one. This is
    what makes the issuer portable and is the reason the custom-domain
    question was decisive.
  - Assert RS256, and that Caddy's `jwtauth` validates offline against the
    Stytch JWKS with no per-request call out — same property the Auth0 setup
    relies on.

  **(c) The trailing-slash audience split behaves.**
  - Serve the PRM `resource` in the slashed form, exactly as production does.
  - Confirm Claude Code (which normalizes via WHATWG and sends the slash) and
    claude.ai (which takes its audience from the PRM field) both land on that
    single audience.
  - Pass = one resource entity serves every client family, as on Auth0. Fail
    = two per service, which roughly doubles the entity arithmetic and
    weakens the cap argument for moving at all.

  **Worth capturing while it is up**, since the marginal cost is near zero:
  whether ChatGPT's connector registration is per connector or per user
  (escalation trigger 3, currently unknown), and whether Stytch applies any
  entity cap to resource/audience registrations rather than only the 10k MAU
  ceiling.

  **Teardown.** Record outcomes here with dates and evidence, in the style of
  the 2026-08-07 and 2026-08-22 entries — the value of this thread has been
  that each claim carries how it was verified. Then delete the spike vhost,
  its DNS record, and the Stytch spike app, so a half-configured second
  issuer is not left standing.

  **Spike run 2026-08-25 — partial, and blocked on a gap the plan did not
  anticipate.** Three of observation (a)'s four bullets answered; (b) and (c)
  untouched. Run against the live Consumer project `project-live-5c01e792…`
  (unique name `chlorinated-nerve-9228`) created 2026-08-24, with a workspace
  management key driving project reads and the project secret driving the
  probe.

  **The plan's setup step is wrong.** It assumed the spike host could front
  "any existing backend or the 2026-08-07 probe server". That holds for Auth0
  only because Universal Login hosts login and consent for us; Stytch does
  not. The application hosts the authorization endpoint. Verified four ways:
  the Connected Apps overview ("your app is responsible for hosting the
  Authorization Endpoint"), the getting-started and existing-auth-system
  guides (both naming `${yourDomain}/oauth/authorize`), and the dashboard's
  own field help — "Location in your web app where the `<IdentityProvider>`
  component is hosted". No hosted alternative exists in the product as
  configured. This is a fourth fit criterion the 2026-08-24 assessment never
  weighed: Stytch is built for developers embedding auth in a product whose
  consent screen is their own surface, whereas we consume identity the way an
  enterprise buys SSO and want the vendor to host everything.

  Practically the lift is smaller than it sounds — `<IdentityProvider />` is a
  frontend-SDK React component talking to Stytch from the browser, so Caddy
  could serve a static bundle from a vhost with no new process. Stytch still
  owns the user store, the auth methods and sessions; what moves to us is
  hosting the pages their components render on. The recurring comparison is
  therefore Auth0 Essentials ($35/mo, cap 10 → 100, materialization deferred
  rather than solved) against Stytch free ($0, no cap at all) plus a static
  page whose marginal cost on existing infrastructure is zero.

  **(a) DCR deduplication — confirmed, with controls.** Nine registrations
  against `…/v1/oauth2/register` produced five entities, then zero after
  cleanup. Identical metadata submitted twice returned one `client_id`; a
  changed `client_name` minted a second, which is the control proving
  registration does mint; a changed redirect *path* minted a third, correctly.
  Dedup keys on the whole metadata document, not on the client name.

  **(a) RFC 8252 loopback normalization — confirmed, and decisive.** Ports
  51234/51235/51236 collapsed to a single `client_id`, and a portless client
  deduped across attempts. That is exactly the debris mode that produced the
  two dead Cursor clients on Auth0, absorbed natively — where
  `scripts/auth0-gc.sh` carries an entire normalization pass setting
  `app_type=native` that exists only to make Auth0 behave the same way.

  **CIMD is advertised**, and there is a trap in how you check. RFC 8414
  metadata on the project domain carries
  `client_id_metadata_document_supported: true`, but the management API's
  `live_idp_cimd_enabled` still reads `false` with the toggle on and the flag
  live — so that field is not trustworthy for a scripted check; read the
  discovery document. The two discovery documents also disagree:
  `api.stytch.com/…/openid-configuration` omits `registration_endpoint` and
  reports a schemeless `issuer: stytch.com/project-live-…`, while the project
  domain's `/.well-known/oauth-authorization-server` carries both correctly
  and is the one MCP clients read.

  **Issuer is portable**, which is what (b) needs: RFC 8414 reports
  `issuer: https://chlorinated-nerve-9228.customers.stytch.com`, a real origin
  a custom domain would replace, and the decoded token agrees. RS256 confirmed.
  One inconsistency worth knowing: the authorization response and the OIDC
  `openid-configuration` document both report a schemeless
  `iss: stytch.com/project-live-…`, which does not match the RFC 8414 value.

  **(b) FAILS, and on the criterion that disqualified Keycloak.** A real token
  was minted end to end — password login, consent via
  `POST /v1/idp/oauth/authorize`, code exchanged at the project domain — and
  its audience is Stytch's *project id*, not the resource:

      aud: ["project-live-5c01e792-05e9-4ab4-a0ee-27cdb3424647"]

  Identical with and without `resource` at the token endpoint. Four mechanisms
  were checked before concluding, because a missed dashboard toggle is exactly
  how this thread went wrong the first time:

  - **RFC 8707 `resource`** — rejected outright at authorize (`unknown field`),
    accepted-then-ignored at token, never advertised in RFC 8414 metadata.
  - **Custom claim templates** — the dashboard states setting `aud` "results in
    an error". Explicitly forbidden.
  - **Project-level "Custom audience"** — works, but one static value for the
    whole project.
  - **`access_token_custom_audience` on the client** — *works*, appending to
    the array: `aud: ["project-live-…", "https://spike.mcp…/"]`. Per **client**,
    though, not per resource.

  That last one is the near miss, and it fails for a reason worth recording:
  one client gets one audience, so a client reaching three services is rejected
  by two of them. DCR deduplication — the feature that made Stytch attractive —
  *guarantees* this, since a client family submitting identical metadata
  collapses to one entity. The two behaviours are in direct tension.
  **Per-service isolation and multi-service clients are mutually exclusive
  within one Stytch project.** The only route that restores the property is one
  Stytch project per service, since `aud` is the project id.

  The 2026-08-24 desk assessment claimed RFC 8707 was "supported, and
  documented specifically for MCP … the per-service `audience_whitelist` model
  in the Caddyfile would survive a move". It does not. That claim traced back
  to secondhand sources; Stytch's own API reference describes `aud` as the
  project id with custom audiences set on the client object.

  **Verdict: do not migrate. The cap is cheaper than the alternatives.**
  Screening the field on resource indicators first — the gate, since failing it
  is disqualifying, where the entity cap has never actually blocked a
  registration — no provider offers per-resource audiences *and* dynamic
  registration *and* a free custom domain:

  | Provider  | RFC 8707            | DCR/CIMD     | Hosted UI | Custom domain |
  |-----------|---------------------|--------------|-----------|---------------|
  | Auth0     | non-standard, works | yes          | yes       | free, in use  |
  | Scalekit  | yes                 | yes, both    | yes       | $99/mo        |
  | WorkOS    | yes                 | yes          | yes       | $99/mo        |
  | Stytch    | no                  | best-in-class| no        | free          |
  | Logto     | yes                 | in developmt | —         | —             |
  | Keycloak  | no                  | CORS-blocked | —         | —             |

  $99/mo is the market rate for resource indicators plus a custom domain, and
  Auth0 Essentials is $35. Every provider clearing the hard criterion costs
  roughly triple the upgrade the migration was meant to avoid, on top of a
  re-consent across three client families. **Pay for Essentials if the cap ever
  blocks a registration**; until then GC plus the log-recency fix keeps us under
  it. Sources: mcp-auth.dev/provider-list, Scalekit MCP quickstart and pricing.

  **Why the isolation is worth keeping** (asked, and worth writing down): all
  three services are third-party code — getzep, an upstream stdio mail server,
  an npm eBay server — and each receives the bearer token on every call. A
  supply-chain compromise in any of them is the most probable failure in this
  design, not an exotic one. Per-service audiences bound that to one service;
  a shared audience would extend it to all mail and the whole memory graph. The
  compose-network partitioning does *not* cover this path, since a compromised
  package reaches the others through the public front door rather than the
  internal network. Audience binding is the only control on it.

  **Torn down 2026-08-27.** The `@spike` vhost block and `caddy/spike/` were
  removed from `main` and the introducing commit rewritten out of history,
  preserved as `archive/stytch-spike-2026-08`. Also deleted: the
  `spike.mcp.nickawilliams.com` DNS record, the Stytch user, both probe client
  sets, the project's authorization URL / DCR / CIMD settings, the SDK
  authorized domain, the `Infrastructure/stytch-project-mcp-spike` 1Password
  item, and the `STYTCH_*` block in `.env`. The probe script was never
  committed.
- **Self-hosting the authorization server (2026-08-27)**: raised after the
  Stytch verdict, since the blocker there was a vendor's audience model rather
  than anything intrinsic. Two libraries were considered.

  **Auth.js is the wrong category** — record it so nobody re-investigates. It
  is a *relying party*: it signs users in against Google, GitHub, Auth0,
  Keycloak. No token issuance to third-party clients, no dynamic registration,
  no authorization server metadata. It would be a client of our issuer, not a
  replacement for it.

  **Better Auth clears the hard criterion, and at zero licence cost** — the
  first option in this whole thread to do so. `@better-auth/oauth-provider`
  is a full OAuth 2.1 authorization server; `@better-auth/mcp` is built for
  this exact shape. Its docs describe `resource` as "the HTTPS protected
  resource identifier that MCP clients request and access tokens carry as the
  `aud` claim" — precisely what Stytch could not do. It also serves RFC 9728
  metadata automatically, supports DCR with per-client resource access enforced
  by default, exposes JWKS for the offline validation our Caddy gate depends
  on, ships a device-authorization flow for CLIs, and tracks the MCP 2026-07-28
  profile. Its 1.7 model is *more* granular than Auth0's: "Audiences have been
  replaced by resources, allowing each resource to define its own token
  lifetime, scopes, claims, and signing keys." Per-resource signing keys is a
  stronger boundary than we have today. No entity caps, because the clients
  live in our own database.

  **Deferred on host placement, not capability** — the distinction matters,
  because placement is the thing that can change. Better Auth is a library, not
  a service: it needs a running Node process and a datastore for users,
  sessions and clients. Putting that on the MCP host would *remove the bulkhead
  the audience model exists to defend*. Today, compromising the box yields the
  services but not the ability to mint tokens, because the signing keys live at
  Auth0. Self-hosted alongside the services, those two failures collapse into
  one: host compromise becomes "issue myself a token for anything, forever" —
  strictly worse than the token-replay case that justified per-service
  audiences in the first place. Hosting it on a separate box preserves the
  boundary but adds a host to run and pay for, which consumes the $420/yr the
  move was meant to save.

  **Revisit if** the health/PHI service lands in its own trust domain (that
  would create a natural home for an issuer outside the MCP blast radius), or
  if Auth0 pricing moves. The reasoning here is placement and operational
  blast radius, not fit — Better Auth is the thing to reach for if we ever do
  leave.
- **Essentials limits confirmed, and the AI add-on is the wrong arrow
  (2026-08-27)**: checked before buying, since the 10 -> 100 figure above came
  from a desk read rather than a source. Auth0's Entity Limit Policy gives
  Applications *and* API resource servers as 10 on Free, **100 on self-service
  (Essentials/Professional)**, 100,000 on Enterprise. Hard limits; only
  Enterprise may request increases. So the purchase does what we expect, plus
  something not previously noted: **the resource-server ceiling lifts too**.
  That was a latent constraint — during the 2026-08-11 trailing-slash period
  each service ran two resource servers, so a fifth service would have hit 10
  on that axis independently of the application cap.

  **Skip the `Auth0 for AI Agents` add-on.** It points the opposite way from
  our architecture: Token Vault (RFC 8693 exchange holding a user's
  Google/Slack/GitHub refresh tokens), async authorization, and FGA for RAG all
  serve *an agent calling out to third-party APIs*. Ours is inbound — MCP
  clients authenticating against resources we own — and Auth0's docs say
  plainly it is "not for securing inbound MCP connections to your own server".
  It adds 50% to the base price (~$53/mo on Essentials) and touches none of the
  quotas above; its Token Vault allocation is a separate quota, easy to mistake
  for the application limit.

  Two parts of it are worth *watching* rather than buying. **Async
  authorization (CIBA)** puts a human approval step in front of an agent
  action, which is a far more interesting control for a future health/PHI
  service than any IdP choice. **Agent Gateway** (listed as planned) covers
  connecting to MCP servers with policy and auditing, which overlaps C0's
  gateway hypothesis and would be a build-vs-buy input if it ships.
- **GC grace window never expires (2026-08-25, fixed 2026-08-27)**:
  `scripts/auth0-gc.sh` pass 2 defers any DCR client that has tenant-log
  activity, but tests only for *existence* of a log row (`per_page=1`, then
  `length > 0`) rather than for recency. The ChatGPT DCR client `tpc_51No…` last
  showed activity on 2026-08-08 and was still being deferred seventeen days
  later, so the script's own promise — "a truly dead registration goes quiet and
  is collected on the next" run — does not hold for it. Fix is to compare the
  newest log `date` against a window instead of counting rows. Context: that
  client is superseded debris rather than an in-flight flow, since ChatGPT has
  moved to CIMD (`tpc_mUge…`, active 2026-08-24) and the DCR entry holds zero
  grants. Tenant went 10/10 → 8/10 on 2026-08-25 when GC reclaimed the two dead
  Cursor clients (`tpc_hX2m…`, `tpc_6CzA…`); one of the remaining eight is this
  stale registration, so a working window would take it to 7/10. The 10/10
  reading also corrects the "8 of 10" recorded in the Stytch verdict above — the
  cap was momentarily full, one registration away from escalation trigger 1,
  rather than comfortably distant.

  **Fixed 2026-08-27.** Pass 2 now compares the *newest* log entry's timestamp
  against `AUTH0_GC_GRACE_DAYS` (default 3) instead of counting rows, with the
  age arithmetic in jq rather than `date(1)` — BSD and GNU disagree on
  relative-date flags and this runs from both a mac and the host. The first
  real run collected `tpc_51No…` immediately (`no grants, stale activity`),
  taking the tenant to **7 of 10**: four first-party and three CIMD, with no
  DCR debris left at all. Three free slots going into the Essentials upgrade.
- **Audience canonicalization split (2026-08-11, resolved 2026-08-22)**:
  clients disagree on the RFC 8707 `resource` form for a bare-origin server.
  claude.ai and ChatGPT send the configured URL verbatim
  (`https://mail.mcp.nickawilliams.com`, matching the PRM `resource`); Claude
  Code sends the WHATWG-normalized form with a trailing slash (a JS `URL` of
  an origin always has path `/`), which the tenant's resource compatibility
  profile exact-matches against resource server identifiers — so Claude Code
  failed with `access_denied: Service not found: <url>/`. Identifiers are
  immutable, so each service ran *both* forms for a while, costing two of the
  free plan's ten resource servers apiece.

  **Collapsed to one form on 2026-08-22.** claude.ai turns out to take its
  audience from the PRM `resource` field Caddy serves, not from its connector
  URL — proven by flipping that field on ebay alone and watching the next
  authorization follow, connector URL unchanged. Pointing the metadata at the
  slashed form therefore moves every client family onto it, so each service
  now registers a single `auth0_resource_server` (`service`, in
  `terraform/modules/service/`) carrying the slashed identifier, and Caddy
  whitelists that one audience. The bare form was withdrawn rather than left
  in place as a second accepted audience: a client holding a stale
  bare-audience token would never 401, so it would never re-read the metadata
  — which is what stalled the migration until the bare form was gone.
- **Need**: support the OAuth-only clients (claude.ai web connectors for individual
  accounts, ChatGPT) in addition to the header-capable dev tools.
- **v1 limitation**: a single endpoint can't cleanly serve both — if it advertises
  OAuth, Claude Code and Cursor ignore the configured static header and force OAuth
  discovery (live client bug; Claude Code #59467 / Cursor forum #156054,
  still-broken as of ~May 2026 — **re-verify before acting**, fast-moving). So v1
  deliberately serves *no* OAuth metadata (bearer only).
  *Re-verified 2026-08-07 (empirically, scratch MCP server serving
  protected-resource + AS metadata and WWW-Authenticate on 401): the bug is
  **fixed** in Claude Code 2.1.220 and absent in Codex CLI 0.114.0 — both send a
  configured static header on every request and never touch the OAuth endpoints
  even when advertised; a headerless Claude Code entry correctly walks the full
  OAuth path (401 → PRM → ASM → DCR → authorize). Cursor untested (GUI-only).
  Conclusion: the **single universal endpoint** (bearer AND OAuth on one
  hostname) is viable — no dual-hostname interim needed.*
  *Phase 2 spike passed 2026-08-07 (scratch Auth0 tenant `nickawilliams`,
  fully Terraform-managed): headerless Claude Code completed real DCR
  (`/oidc/register`), PKCE auth-code with the RFC 8707 `resource` param, and
  called the probe MCP server with an RS256 `rfc9068_profile` JWT verified
  offline via JWKS — audience bound exactly to the resource identifier.
  Key discovery: third-party (DCR) clients **always** need a client grant
  regardless of the API's `allow_all` user policy; the production shape is a
  per-service **default grant** (`auth0_client_grant` with
  `default_for = "third_party_clients"`, `subject_type = "user"`) — supported
  in the official provider (verified v1.54). Architecture decision (same
  date): identity is a **core concern** — tenant-level Auth0 config + the
  `auth.nickawilliams.com` custom domain (free tier includes exactly one;
  it becomes the permanent issuer) live in the infrastructure repo; only
  per-service `auth0_resource_server` + default grants live here, consuming
  the issuer via `terraform_remote_state` exactly like `zone_id`.*
- **Candidate v2 mechanism**: near-term — a **second hostname** (`<svc>-oauth.mcp.…`)
  with a managed IdP (WorkOS AuthKit / Auth0 / …) as authorization server and
  Caddy/graphiti as resource server; per-hostname isolation keeps the OAuth host
  from poisoning the bearer host. End-state — a **single universal endpoint** that
  offers bearer *and* OAuth once the client header-override bug is fixed.
  **Cognito ruled out** (2026-08-07): no RFC 7591 dynamic client registration —
  MCP clients DCR on first contact (observed empirically in the 2026-08-07
  client tests), and the workaround is a custom APIGW+Lambda facade, i.e.
  building the security-critical plumbing a managed IdP exists to avoid.
  Static-bearer management stays local (Caddy string-compare + 1Password/
  terraform loop) even after OAuth lands: WorkOS's API Keys product validates
  via a per-request network call to WorkOS — a runtime dependency the machine
  path exists to not have.
- **Trigger to build**: wanting graphiti as a claude.ai-web or ChatGPT connector.
  **Escalated 2026-07-22**: the mail service (full read/write/send access to all
  mail accounts) now sits behind a static bearer token — C4 (or a Tailscale-only
  binding, which is a tenth of the effort but forecloses web connectors) is the
  **designated next major platform addition**. Interacts with C2/the gateway:
  a real identity layer is what token→group/tool enforcement wants to bind to.
  **Escalated again 2026-08-07**: the bearer-only shape is now costing
  *reliability*, not just reach — the `mcp-remote` stdio shim (required for
  config parity with header-incapable clients) suffers OAuth-coordination
  lockfile contention under many concurrent Claude instances (SIGTERM at the
  client's 30 s ceiling orphans `~/.mcp-auth/*/_lock.json`; the next spawn
  blocks on the dead holder → self-perpetuating `tools/list` timeouts; 29
  occurrences in client logs). Interim mitigations shipped (stale-lock
  cleanup; Caddyfile 404s on `/.well-known/oauth-*` probe paths ahead of the
  bearer gate — **deliberate scaffolding, to be removed when this entry lands**,
  since the OAuth host must serve exactly those paths). The structural fix is
  this entry: native OAuth+bearer makes every client a plain-URL config and
  retires the shim entirely.
- **Caveats**: OAuth is hostile to headless/automation contexts (needs a browser);
  the bearer path must stay for scripts/CI. This is largely independent of the MCP
  gateway (it's a Caddy + IdP concern), so it can land on its own timeline.
- **Interim (v1) mitigation**: bearer covers 100% of clients actually run on your
  own machines; the two web connectors simply aren't wired up. Hardening landed
  with the mail service (2026-07-22): per-service tokens (already), per-service
  compose networks (no lateral container access to unauthenticated backends),
  Caddy structured access logs (audit trail). Tokens live in 1Password
  (`mcp-bearer-<svc>`, 2026-07-25), so client configs can hold `op://` refs
  instead of literals.
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
- **v1 limitation**: this repo builds no software — it cannot carry a
  codebase, and on-host source builds are undesirable (2026-07-21).
  *Update 2026-07-25: the SSM file bus is retired — the host now tracks the
  git repo directly and SSM carries secrets only — but the no-codebase rule
  stands; the gateway still arrives as an external image.*
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

### C7 — Trust domain for high-sensitivity services (health / PHI)
- **Need**: a service holding protected health information should not share a
  blast radius with an npm eBay client. Raised 2026-08-27 while weighing
  whether per-service token isolation was worth preserving; the answer was
  yes, but it also exposed the limit of what that isolation buys.
- **v1 limitation**: audience binding bounds *token* blast radius — a
  compromised service holds a token good only for itself — but says nothing
  about *host* blast radius. All services share one EC2 box, one Caddy, one
  docker daemon, and one `.env` carrying every service's secrets, flattened
  there by `refresh.sh`. Compose networks isolate container-to-container, and
  audiences isolate tokens, but a host-level compromise is above both. Today
  that ceiling is acceptable because the worst case is email and a memory
  graph; PHI changes the calculus, and unlike the other two it carries
  external obligations.
- **Candidate v2 mechanism**: a second host in its own trust domain — its own
  EC2 instance, its own Caddy, its own SSM path prefix, so the shared `.env`
  never carries its secrets. Reuses everything else unchanged: the same
  `modules/service` surface, the same Auth0 issuer and per-service audiences,
  the same DNS pattern. Roughly the cost of a second small instance plus a
  second terraform workspace. A weaker variant — same host, separate docker
  daemon or a rootless runtime — buys less and complicates delivery, since the
  repo root *is* the checkout.
- **Trigger to build**: the health service becoming real. Deciding this before
  it lands is much cheaper than migrating it afterwards, because moving a
  service across trust domains is a re-consent event for every client family
  holding a grant against it.
- **Caveats**: a second host doubles the patching and monitoring surface for a
  userbase of one, and does not help if the *client* is compromised — Claude
  Code legitimately holds grants against both domains, which no amount of
  server-side partitioning addresses. Also worth noting a hosted issuer is
  what keeps signing keys outside both blast radii; this entry is an argument
  against self-hosting the authorization server on either host (see the
  self-hosting entry under C4).
- **Interim (v1) mitigation**: none needed — no such service exists yet. The
  point of logging it now is that the decision has a natural moment, and that
  moment is before the first PHI byte lands, not after.
- *Logged: 2026-08-27*

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
- **ChatGPT connector tool-surface requirements.** ChatGPT compatibility is not
  only auth (C4): its connector modes carry tool-shape expectations (deep
  research wants `search`/`fetch` tools; developer mode relaxes this — verify
  current state when wiring it up). Separate axis from identity; possibly a
  gateway (C3) concern if services shouldn't each grow ChatGPT-shaped tools.

---

## Near-term backlog (v1 hardening — not v2)

Small operational gaps to close within v1, independent of the v2 vision:

- ~~**Implement `make deploy`**~~ — done 2026-07-21: `refresh.sh` (rendered,
  SSM-delivered) pulls all config/secrets by path and reconciles compose; both
  cloud-init and `make deploy` run it, so first boot and config pushes are one
  mechanism. *Superseded 2026-07-25: delivery is now GitOps — the host is a
  checkout of this repo, refresh.sh is a tracked literal script, and SSM
  carries secrets only.*
- ~~**Token-rotation runbook**~~ — done 2026-07-21 (per-service tokens landed
  with the services/ restructure):
  `terraform apply -replace='module.<name>.random_password.bearer'` →
  `make deploy` → update that service's clients
  (`op://Infrastructure/mcp-bearer-<name>/password` refresh, or
  `terraform output -json service_bearer_tokens`). Other services unaffected;
  the 1Password item updates in the same apply (write-back, 2026-07-25).
- **Pin the graphiti image to a digest** — currently rides mutable
  `zepai/knowledge-graph-mcp:standalone`. The silent-drift risk is real: upstream has
  reworded the instructions constant and uses nested env binding
  (`GRAPHITI__GROUP_ID`); a schema/behavior change on pull could quietly land writes
  in the wrong namespace. Pin + eyeball the startup log (`Using group_id`,
  `Using database`) after any deliberate bump.
- **Retire the stale claude.ai `Graphiti[id=…]` connector** (web UI) — throws
  `-32000` reconnect noise and embeds the token in its command line.
