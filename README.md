# MCP

Self-hosted MCP (Model Context Protocol) services, reachable at
`<service>.mcp.nickawilliams.com`. This repo owns the shared host and every
service that runs on it. Current services: **graphiti** (long-term-memory
knowledge graph), **mail** (multi-account IMAP/SMTP email, the stdio
upstream wrapped by a supergateway streamable-HTTP bridge), and **ebay**
(eBay Sell-API tools, a native streamable-HTTP Node server from npm).

## Architecture

A single arm64 EC2 host runs the services under docker-compose, fronted by
[Caddy](https://caddyserver.com) for TLS and authentication. Each service is a
container plus a `<service>.mcp.nickawilliams.com` record; adding one is a new
entry in the `services` map.

```
graphiti.mcp.nickawilliams.com --443--> Caddy (auto-TLS + bearer auth)
mail.mcp.nickawilliams.com     --443-/    -> graphiti-mcp  (:8000 /mcp)
ebay.mcp.nickawilliams.com     --443-/    -> falkordb      (graph DB)
                                          -> mail-mcp      (:8080 /mcp)
                                          -> ebay-mcp      (:8081 /)
```

Each service lives on its own compose network with only Caddy attached to
all of them, so containers cannot reach another service's backend directly.
Caddy writes a structured access log (audit trail) to docker logs.

- **Compute**: one EC2 host (not ECS/ALB) — single-user, stateful graph DB,
  ~1/3 the cost. TLS terminates on the box via Caddy + Let's Encrypt (a
  `*.mcp.nickawilliams.com` wildcard via Route53 DNS-01). No SSH; shell access
  is via SSM Session Manager (`make ssm`).
- **Auth**: Caddy enforces a static bearer token **per service** (rotate one
  with `terraform apply -replace='module.<name>.random_password.bearer'`
  then `make deploy`; clients read tokens from 1Password —
  `op://Infrastructure/mcp-bearer-<name>/password` — or via
  `terraform output -json service_bearer_tokens`). Backends bind to localhost
  only, so the sole public surface is Caddy `:443`.
- **Delivery**: git is the source of truth for files — the host's `/opt/mcp`
  is a checkout of this (public) repo, advanced by `make deploy` (fetch +
  `reset --hard origin/main`, then `scripts/refresh.sh`). Terraform delivers
  only what it owns: AWS resources and secrets (SSM `/common/mcp/secrets/*`,
  flattened into the host `.env` by refresh.sh). Untracked runtime content
  (`data/`, `.env`) lives alongside the checkout.

## This repo vs. the infrastructure core

`~/Projects/infrastructure` is the neutral core: it owns the `nickawilliams.com`
root zone and exposes it as `zone_id`. This repo consumes that hook via
`terraform_remote_state` and is otherwise self-contained — it **owns its own
`mcp.nickawilliams.com` child zone and the NS delegation into root**, so a
`terraform destroy` here reverts to the pre-MCP state without touching the core.
The dependency arrow only points inward: `[ infrastructure/common ] <-- [ mcp ]`.

## Layout

The repo is partitioned by concern: `terraform/` is all IaC — a root platform
module (host, DNS, secrets) plus one single-use module per service — and
`services/<name>/` is a service's runtime payload and docs. The repo root IS
`/opt/mcp` on the host (a git checkout), so every tracked path is already at
its delivered location. Future non-IaC codebases (e.g. an MCP gateway) slot
in as new top-level directories.

```
mcp/
├── docker-compose.yaml    # platform compose: Caddy + include of each service
├── Dockerfile.caddy       # Caddy + Route53 DNS plugin (built on the host)
├── caddy/
│   └── Caddyfile          # TLS + bearer-gated vhost per service (tokens
│                          #   arrive as {$MCP_TOKEN_*} env at parse time)
├── scripts/
│   └── refresh.sh         # host sync: SSM secrets -> .env, compose reconcile
├── services/
│   └── graphiti/          # one payload directory per MCP service
│       ├── README.md      #   ops doc (setup, reseed), when comments don't
│       │                  #   suffice — see services/ebay/README.md
│       ├── compose.yaml   #   its containers (included by the root compose)
│       ├── config.yaml    #   its config
│       └── docs/          #   payload docs (client instruction block, etc.)
├── terraform/             # root platform module (host, DNS, secrets)
│   ├── services.tf        #   service manifest: one module block per service
│   └── modules/
│       └── graphiti/      #   per-service module: registry identity, token,
│                          #   DNS, service-specific extras
├── Makefile               # ops wrapper (op run + terraform; ssm/logs/deploy)
├── .env                   # 1Password op:// refs, gitignored (see Credentials)
└── README.md
```

- **State key**: `525999333867/us-west-1/nickawilliams/common/mcp/terraform.tfstate`
  in the `terraform-state-nickawilliams` bucket (S3-native locking).
- **Resource naming**: `common-mcp-<resource>`. **SSM paths**: `/common/mcp/secrets/*`.

## Credentials

`.env` at the repo root is the single entry point — every secret is a 1Password
`op://` reference, resolved at run time by `op run --env-file=.env` (wrapped by
the `Makefile`). AWS credentials come from the ambient profile. The file is
gitignored.

The `onepassword` provider authenticates as the **`mcp-terraform` service
account** (read/write to the Infrastructure vault only; its token lives in
the Private vault as `op-service-account-mcp-terraform`, fed through a
`TF_VAR` so shell `op` keeps desktop-app auth). Terraform **writes the
per-service bearer tokens back** to the Infrastructure vault as
`mcp-bearer-<service>` items (naming grammar
`<system>-<component>[-<instance>]`, `terraform` tag + `metadata` section —
see the infrastructure repo's Credentials convention), so the vault always
reflects what was last applied and clients configure tokens by `op://`
reference instead of terraform output.

## Workflow

```sh
make init
make fmt validate
make plan
make apply    # create/update AWS resources + SSM secrets
make deploy   # host: git fetch + reset --hard origin/main, then refresh.sh
```

Files deploy via **git push + `make deploy`** (the host advances its checkout,
re-pulls secrets from SSM, and reconciles compose — via SSM send-command, the
same sequence cloud-init runs at first boot). `apply` is only needed when AWS
resources or secret values change. Unpushed work never reaches the host;
`make deploy` warns when HEAD ≠ origin/main.

`make` is also the CI control plane: GitHub Actions workflows under
`.github/workflows/` are thin wrappers over make targets (e.g.
`make publish/mail-mcp` builds and pushes the mail-mcp arm64 image that
upstream doesn't publish). Logic lives in the Makefile; workflows only do
provider plumbing (checkout, registry login, runners). See `AGENTS.md`.

## Adding a service

1. Create `services/<name>/compose.yaml` (its containers; relative paths are
   from `/opt/mcp`, e.g. `./services/<name>/config.yaml`, `./data/<dir>`),
   declaring and joining its own network. In the root `docker-compose.yaml`,
   add an `include` entry, declare the network, attach caddy to it, and add
   the `MCP_TOKEN_<NAME>=${MCP_TOKEN_<NAME>}` caddy env line.
2. Add the service's vhost block to `caddy/Caddyfile` (host matcher, bearer
   gate on `{$MCP_TOKEN_<NAME>}`, rewrites, `reverse_proxy`). If it has
   persistent data, add its dir to the `mkdir -p data/...` line in
   `scripts/refresh.sh`.
3. Create `terraform/modules/<name>/` — copy `modules/graphiti/` as the
   scaffold and adjust: the registry identity (subdomain), the token param
   basename, and any service-specific extras (API keys, SSM secrets). The
   scaffold already yields the DNS record and the bearer token. Secret
   basenames must be unique across services (they share the host's `.env`).
4. Register it: a `module "<name>"` block in `terraform/services.tf` and
   entries in the `services` / `service_tokens` maps in `terraform/locals.tf`.
5. If the service needs operational documentation beyond file comments
   (credential setup, token reseeds, upstream quirks), put it in
   `services/<name>/README.md`. `docs/` is for payload files the service
   itself consumes or serves, not operator docs.
6. `make plan && make apply`, then commit + push + `make deploy`.

Removing a service is the inverse: delete both directories and the manifest,
compose, and Caddyfile entries; the module's resources (token param, DNS)
retire with it.
