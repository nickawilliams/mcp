# MCP

Self-hosted MCP (Model Context Protocol) services, reachable at
`<service>.mcp.nickawilliams.com`. This repo owns the shared host and every
service that runs on it. The first service is **graphiti** (a long-term-memory
knowledge-graph MCP server).

## Architecture

A single arm64 EC2 host runs the services under docker-compose, fronted by
[Caddy](https://caddyserver.com) for TLS and authentication. Each service is a
container plus a `<service>.mcp.nickawilliams.com` record; adding one is a new
entry in the `services` map.

```
graphiti.mcp.nickawilliams.com --443--> Caddy (auto-TLS + bearer auth)
                                          -> graphiti-mcp  (:8000 /mcp/)
                                          -> falkordb      (graph DB)
```

- **Compute**: one EC2 host (not ECS/ALB) — single-user, stateful graph DB,
  ~1/3 the cost. TLS terminates on the box via Caddy + Let's Encrypt (a
  `*.mcp.nickawilliams.com` wildcard via Route53 DNS-01). No SSH; shell access
  is via SSM Session Manager (`make ssm`).
- **Auth**: Caddy enforces a static bearer token **per service** (rotate one
  with `terraform apply -replace='module.<name>.random_password.bearer'`
  then `make deploy`; read tokens via
  `terraform output -json service_bearer_tokens`). Backends bind to localhost
  only, so the sole public surface is Caddy `:443`.

## This repo vs. the infrastructure core

`~/Projects/infrastructure` is the neutral core: it owns the `nickawilliams.com`
root zone and exposes it as `zone_id`. This repo consumes that hook via
`terraform_remote_state` and is otherwise self-contained — it **owns its own
`mcp.nickawilliams.com` child zone and the NS delegation into root**, so a
`terraform destroy` here reverts to the pre-MCP state without touching the core.
The dependency arrow only points inward: `[ infrastructure/common ] <-- [ mcp ]`.

## Layout

The repo is partitioned by concern: `terraform/` is all IaC — a root platform
module (host, DNS, Caddy, delivery) plus one single-use module per service —
and `services/<name>/` is a service's runtime payload and docs. The top level
mirrors `/opt/mcp` on the host: `docker-compose.yaml` and each
`services/<name>/` land there at the same relative paths (minus
documentation, which stays local). Future non-IaC codebases (e.g. an MCP
gateway) slot in as new top-level directories.

```
mcp/
├── docker-compose.yaml    # platform compose: Caddy + include of each service
├── services/
│   └── graphiti/          # one payload directory per MCP service
│       ├── compose.yaml   #   its containers (included by the root compose)
│       ├── config.yaml    #   its config (ships to the host; so does any
│       │                  #   other file here except docs/ and *.md)
│       └── docs/          #   its docs (client instruction block, etc.)
├── terraform/             # root platform module (host, DNS, Caddy, delivery)
│   ├── services.tf        #   service manifest: one module block per service
│   └── modules/
│       └── graphiti/      #   per-service module: registry identity, token,
│                          #   DNS, file delivery, service-specific extras
├── Makefile               # ops wrapper (op run + terraform; ssm/logs/deploy)
├── .env                   # 1Password op:// refs, gitignored (see Credentials)
└── README.md
```

- **State key**: `525999333867/us-west-1/nickawilliams/common/mcp/terraform.tfstate`
  in the `terraform-state-nickawilliams` bucket (S3-native locking).
- **Resource naming**: `common-mcp-<resource>`. **SSM paths**: `/common/mcp/{config,secrets}/*`.

## Credentials

`.env` at the repo root is the single entry point — every secret is a 1Password
`op://` reference, resolved at run time by `op run --env-file=.env` (wrapped by
the `Makefile`). AWS credentials come from the ambient profile. The file is
gitignored.

## Workflow

```sh
make init
make fmt validate
make plan
make apply    # create/update AWS resources + push rendered config to SSM
make deploy   # host re-pulls config/secrets from SSM and reconciles compose
```

`apply` updates the SSM parameters; the running host only picks them up on
`deploy` (which runs `refresh.sh` on the box via SSM send-command — the same
script cloud-init runs at first boot).

## Adding a service

1. Create `services/<name>/compose.yaml` (its containers; relative paths are
   from `/opt/mcp`, e.g. `./services/<name>/config.yaml`, `./data/<dir>`) and
   add an `include` entry for it in the root `docker-compose.yaml`.
2. Create `terraform/modules/<name>/` — copy `modules/graphiti/` as the
   scaffold and adjust: the registry identity (subdomain, upstream, MCP path,
   data dirs), the payload dir, and any service-specific extras (API keys,
   SSM secrets). The scaffold already yields the DNS record, the bearer-gated
   Caddy vhost + token, and file delivery to the host. Secret basenames must
   be unique across services (they share the host's `.env`).
3. Register it: a `module "<name>"` block in `terraform/services.tf` and
   entries in the `services` / `service_tokens` maps in `terraform/locals.tf`.
4. `make plan && make apply && make deploy`.

Removing a service is the inverse: delete both directories and the manifest
entries; the module's resources (params, DNS, token) retire with it.
