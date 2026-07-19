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
- **Auth**: Caddy enforces a static bearer token; the graph DB and the MCP
  server bind to localhost only, so the sole public surface is Caddy `:443`.

## This repo vs. the infrastructure core

`~/Projects/infrastructure` is the neutral core: it owns the `nickawilliams.com`
root zone and exposes it as `zone_id`. This repo consumes that hook via
`terraform_remote_state` and is otherwise self-contained — it **owns its own
`mcp.nickawilliams.com` child zone and the NS delegation into root**, so a
`terraform destroy` here reverts to the pre-MCP state without touching the core.
The dependency arrow only points inward: `[ infrastructure/common ] <-- [ mcp ]`.

## Layout

```
mcp/
├── terraform/   # all IaC (see below)
├── Makefile     # ops wrapper (op run + terraform; ssm/logs/deploy)
├── .env         # 1Password op:// refs, gitignored (see Credentials)
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
make apply
```

## Adding a service

Add an entry to the `services` map in `terraform/locals.tf` (image, subdomain,
container port, required secrets), add its secrets to `.env`, then
`make plan && make apply`. It gets a DNS record, a Caddy vhost, and a
compose service.
