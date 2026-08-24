# Agents

## Build & CI

- `make` is the control plane for all build, CI, and ops tasks. GitHub
  Actions workflows are thin wrappers over make targets (near 1:1 linkage);
  logic goes in the `Makefile`, only provider plumbing (checkout, registry
  login, runner setup) goes in workflow YAML.
- Credentials are ambient: AWS from the environment profile, registry auth
  from `docker login` (locally) or `docker/login-action` (CI), 1Password via
  `op run --env-file=.env` (already wrapped by the Makefile's terraform
  targets).

## Deployment

- Files reach the host via git: commit + **push**, then `make deploy`
  (the host checkout advances to origin/main and refresh.sh reconciles).
  `make apply` is only for AWS resources and secret values. Unpushed work
  never deploys.

## Commits

- Conventional Commits with a scope, matching the existing history:
  `iac(mcp):`, `docs(mcp):`, `chore(mcp):`.

## Auth failures

- A client that cannot authorize is almost always an unregistered client, not
  a broken token. Two mechanisms, two different failures: `403 limit of
  entities` is DCR against the free plan's 10-app cap (`make maintenance/gc
  GC=--dry-run`); `invalid_request: Unknown client: <url>` is CIMD needing a
  `cimd_clients` entry in the infrastructure repo (`make
  maintenance/cimd-pending` prints the URL to add). Run the matching probe
  before touching Caddy or the resource servers — see ROADMAP.md, "DCR vs
  CIMD", for which side owns each limit.

## Conventions

- Template a delivered file (`*.tftpl`) only when it must embed values
  terraform knows (tokens, addresses, computed config). Keep everything
  else literal — literal compose/config files can be validated locally
  (`docker compose config`) before a deploy cycle. Exactly one templated
  file remains: `cloud-init.sh.tftpl` (user_data needs region/prefix).
- YAML files use the full `.yaml` extension, never `.yml`.
- Architecture and design live in `README.md` and `ROADMAP.md` — this file
  stays behavioral.
