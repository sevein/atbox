# atbox

`atbox` packages [AtoM](https://github.com/artefactual/atom) into a
production-oriented container focused on read-only access patterns.

## What this image is for

- Serve AtoM over `nginx` + `php-fpm` with `s6-overlay` supervision.
- Keep runtime web services (`nginx`, `php-fpm`) on a non-root user.
- Support read-only browsing workloads backed by external MySQL and
Elasticsearch.

This image does not run background Gearman workers.

## Scope and non-goals

`atbox` is intentionally narrow in scope: a minimal, reliable, read-oriented
AtoM runtime container. It does not automatically bootstrap persistent state or
orchestrate environment-specific migration workflows (for example SQL dump
import, one-time Elasticsearch population, or cross-service idempotency/state
tracking). That transitional/bootstrap logic belongs outside this image so the
`atbox` runtime remains simple, stable, and reusable across environments.

## Run

```bash
docker run --rm -p 8080:8080 \
  -e ATOM_ELASTICSEARCH_HOST=elasticsearch:9200 \
  -e ATOM_MYSQL_DSN='mysql:host=mysql;dbname=atom;charset=utf8mb4' \
  -e ATOM_MYSQL_USERNAME=atom \
  -e ATOM_MYSQL_PASSWORD='replace-me' \
  ghcr.io/sevein/atbox:<tag>
```

Then open `http://localhost:8080`.

For local development builds from this repository, see `CONTRIBUTING.md`.

## Required environment variables

- `ATOM_ELASTICSEARCH_HOST`
- `ATOM_MYSQL_DSN`
- `ATOM_MYSQL_USERNAME`
- `ATOM_MYSQL_PASSWORD`

## Optional environment variables

- `ATBOX_RUNTIME_USER` (default: `atbox`)

## Read-only behavior notes

- `read_only` is forced to `true` in generated AtoM config.
- File uploads are disabled in PHP (`file_uploads=Off`, upload limits forced to
zero).
- Application cache uses `sfAPCCache` (APCu); sessions use Symfony
`sfSessionStorage`.
- Nginx, PHP-FPM, and Symfony logs are emitted directly to container
stdout/stderr (no file tail sidecar pattern).

## Known gaps

- Strict container filesystem immutability is not implemented yet (`docker run
--read-only` / Kubernetes `readOnlyRootFilesystem: true`).
- Runtime config generation is still done by `atbox-bootstrap.php` at container
start; build-time static templates/env-only config is not implemented yet.
- Symfony cache/OPcache warmup is not precomputed at image build time (no
build-time `php symfony cc` warm path and no OPcache preload script yet).
- Memcache-based cache backend integration is not implemented yet (current
cache backend is APCu via `sfAPCCache`).
- Least-privilege capability minimization is not complete yet (current
hardening validates `no-new-privileges` and drops `CAP_NET_RAW`, but broader
capability reduction is still pending).
