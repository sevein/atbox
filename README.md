# atbox

`atbox` packages [AtoM](https://github.com/artefactual/atom) into a
production-oriented container focused on read-only access patterns.

## What this image is for

- Serve AtoM over `nginx` + `php-fpm` with `s6-overlay` supervision.
- Keep runtime web services (`nginx`, `php-fpm`) on a non-root user.
- Support read-only browsing workloads backed by external MySQL, Elasticsearch
  and Memcached.

## Design principles

### Monolithic runtime unit

`atbox` is a single container that runs:

- `s6-overlay` as init/supervisor (`/init`)
- `nginx` (HTTP server)
- `php-fpm` (application runtime)

This is intentional for AtoM's legacy Symfony 1.x deployment model: fewer moving
pieces, predictable startup ordering, and a simpler operational model for
read-mostly workloads.

### Logging and observability defaults

- Runtime services are expected to log directly to container streams.
- `php-fpm` is configured to run in foreground with `-O` and global logs routed
  to container output.
- Symfony/application logging is configured for warning-level and above.
- No file-tail sidecars; no background `tail -f` log shims.

### Read-only application behavior

- AtoM is forced into `read_only: true`.
- Uploads are disabled at PHP level.
- Session and cache behavior are explicitly configured for this profile.

### Cache architecture decisions

`atbox` uses external Memcached for application cache and session storage, and
keeps PHP OPcache as an in-process opcode cache. `ATOM_NAMESPACE` scopes both
cache keys and the session cookie name.

### HTTP method policy

In this public read-only profile, `nginx` allows only `GET` and `HEAD` requests
at the edge and rejects all other HTTP methods.

### Artifact generation policy

The read-only profile is for serving existing artifacts, not for anonymous
report-generation workflows that enqueue jobs and create new files under
`downloads/reports`. If you need report, finding-aid, or export generation,
run those workflows in a separate authenticated writer/admin tier.

### Shared media storage model

In multi-instance deployments, `uploads/` should use shared durable storage (for
example NFS), and `downloads/` should be shared only if generated artifacts
must be available from every instance. Public read-only instances should mount
these paths as read-only, while the writer/admin tier should be the only one
with read-write mounts. Native object-storage semantics are not first-class in
this image yet, so object storage currently requires an external integration
layer; upstream support remains a future direction.

## Operational profile

- HTTP listen port: `8080`
- Runtime user: `atbox` (UID/GID configurable)
- External dependencies: MySQL + Elasticsearch + Memcached
- Process supervision: `s6-overlay`

## Scope and non-goals

`atbox` is intentionally narrow in scope: a minimal, reliable, read-oriented
AtoM runtime container. It does not automatically bootstrap persistent state or
orchestrate environment-specific migration workflows (for example SQL dump
import, one-time Elasticsearch population, or cross-service idempotency/state
tracking). That transitional/bootstrap logic belongs outside this image so the
`atbox` runtime remains simple, stable, and reusable across environments.

In read-only environments, exposing existing files from `uploads/*` and
`downloads/*` is expected; creating new user-triggered artifacts from anonymous
requests is not part of the supported profile.

## Run

```bash
docker run --rm -p 8080:8080 \
  -e ATOM_ELASTICSEARCH_HOST=elasticsearch:9200 \
  -e ATOM_MEMCACHED_HOST=memcached:11211 \
  -e ATOM_NAMESPACE=atom-prod-a \
  -e ATOM_MYSQL_DSN='mysql:host=mysql;dbname=atom;charset=utf8mb4' \
  -e ATOM_MYSQL_USERNAME=atom \
  -e ATOM_MYSQL_PASSWORD='replace-me' \
  ghcr.io/sevein/atbox:<tag>
```

Then open `http://localhost:8080`.

For local development builds from this repository, see `CONTRIBUTING.md`.

## Configuration reference

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `ATOM_ELASTICSEARCH_HOST` | Yes | none | Elasticsearch endpoint (`host[:port]`). |
| `ATOM_MEMCACHED_HOST` | Yes | none | Memcached endpoint (`host[:port]`). |
| `ATOM_MYSQL_DSN` | Yes | none | PDO DSN for MySQL. |
| `ATOM_MYSQL_USERNAME` | Yes | none | MySQL username. |
| `ATOM_MYSQL_PASSWORD` | Yes | none | MySQL password. |
| `ATOM_NAMESPACE` | No | `atom` | Shared namespace used for both Memcached key prefix and session cookie name. Set per tenant/deployment to avoid cross-tenant collisions. |
