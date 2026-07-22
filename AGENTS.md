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

- `make apply` only updates AWS resources and SSM parameters. Nothing
  reaches the running host until `make deploy`. A config change is not live
  until both have run.

## Commits

- Conventional Commits with a scope, matching the existing history:
  `iac(mcp):`, `docs(mcp):`, `chore(mcp):`.

## Conventions

- YAML files use the full `.yaml` extension, never `.yml`.
- Architecture and design live in `README.md` and `ROADMAP.md` — this file
  stays behavioral.
