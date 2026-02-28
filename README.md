# atbox

`atbox` packages [AtoM](https://github.com/artefactual/atom) into a production-oriented container focused on read-only access patterns.

## What this image is for

- Serve AtoM over `nginx` + `php-fpm` with `s6-overlay` supervision.
- Keep runtime web services (`nginx`, `php-fpm`) on a non-root user.
- Support read-only browsing workloads backed by external MySQL and Elasticsearch.

This image does not run background Gearman workers.

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
- File uploads are disabled in PHP (`file_uploads=Off`, upload limits forced to zero).
- Cache/session storage uses local filesystem under `/tmp/atom`.
