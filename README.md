# atbox

`atbox` packages [AtoM](https://github.com/artefactual/atom) as a small,
role-based container image family plus a Helm chart for attached deployments.
The project is scoped around separating public read traffic from authenticated
metadata-editing and lifecycle tasks while keeping all roles built from the same
AtoM source and dependency layers.

- `ghcr.io/sevein/atbox-public`: public read-only web runtime.
- `ghcr.io/sevein/atbox-admin`: authenticated metadata-editing web runtime.
- `ghcr.io/sevein/atbox-cli`: lifecycle/CLI runtime for one-shot jobs.
- `ghcr.io/sevein/atbox-worker`: long-running AtoM Gearman worker runtime.

The chart in `charts/atbox` provides presets for read-only, admin-only, and
public-plus-admin topologies where MySQL, Elasticsearch, Memcached, and
Gearman are provided externally.

## What this project is for

- Serve AtoM over `nginx` + `php-fpm` with `s6-overlay` supervision for web
  roles.
- Keep runtime web services (`nginx`, `php-fpm`) on a non-root user.
- Support public read-only browsing workloads backed by external MySQL,
  Elasticsearch, and Memcached.
- Isolate admin metadata-editing behavior in a separate image instead of a
  runtime switch on the public image.
- Provide a CLI image for lifecycle commands such as search indexing.
- Provide a worker image for AtoM background jobs backed by external Gearman.
- Ship Helm presets and validation coverage alongside the images.

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

### Admin application behavior

`atbox-admin` is a separate image target, not a runtime switch on the public
image. It enables AtoM write behavior and accepts legacy form `POST` requests,
with uploads disabled by default. Enable uploads only when the admin tier has
shared writable `uploads/` storage and an accompanying worker tier.

### Worker behavior

`atbox-worker` bootstraps the same AtoM config, connects to external Gearman,
and runs `php -d memory_limit=-1 -d error_reporting=E_ALL symfony jobs:worker`
as the non-root `atbox` user. The image includes the media and document tooling
used by AtoM jobs through the Nix-defined worker toolchain, including
ImageMagick, Ghostscript, Poppler, FFmpeg, Java, Apache FOP, and Unzip.

### AtoM toolchain

The repository includes a Nix flake that defines the external command-line
tools AtoM expects from the runtime environment. The flake entrypoint remains
at the repository root, while the tool manifest and Nix implementation live
under `nix/`. This scope is intentionally limited to tools AtoM shells out to
directly, plus Ghostscript as the ImageMagick delegate required for PDF
derivatives. The covered paths are digital object derivatives, PDF text
extraction, PDF finding aid generation, SWORD package extraction, and small
command probes:

- ImageMagick: `convert`, `identify`, `mogrify`, `composite`, `magick`
- Ghostscript: `gs`, `ps2pdf`
- FFmpeg: `ffmpeg`, `ffprobe`
- Poppler utilities: `pdfinfo`, `pdftotext`
- Apache FOP: `fop`
- Java: `java`
- Unzip: `unzip`
- Which: `which`

The aggregate packages are:

- `.#atbox-toolchain`: all managed AtoM tools.
- `.#atbox-admin-toolchain`: tools needed by admin web paths that can run in
  the request, including digital object uploads, derivative generation, PDF text
  extraction, and repository theme image cropping.
- `.#atbox-cli-toolchain`: tools needed by AtoM CLI tasks that generate digital
  object derivatives, extract text, or generate finding aids.
- `.#atbox-worker-toolchain`: tools needed by worker jobs, including finding
  aid generation, queued imports, derivative generation, text extraction, and
  SWORD package extraction.

Docker builds use these role-specific Nix aggregates as the source for AtoM
external command tools in the admin, CLI, and worker images. The public
read-only image does not include the AtoM toolchain.

Useful Nix commands on Linux, or on another host with a Linux builder:

```bash
nix build .#atbox-worker-toolchain
nix build .#atbox-cli-toolchain
nix run .#version-report
nix develop
```

The toolchain does not include service dependencies or language/runtime
packages such as MySQL, Elasticsearch, Memcached, Gearman, PHP extensions,
`nginx`, `s6-overlay`, or the Saxon and XML resolver jars bundled by AtoM.
Those remain part of the application image, external services, or AtoM source
tree as appropriate.

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
`downloads/reports`. If you need report, finding-aid, or export generation, run
those workflows in a separate authenticated writer/admin tier.

### Shared media storage model

In multi-instance deployments, `uploads/` should use shared durable storage (for
example NFS), and `downloads/` should be shared only if generated artifacts must
be available from every instance. Public read-only instances should mount these
paths as read-only, while the writer/admin tier should be the only one with
read-write mounts. Native object-storage semantics are not first-class in this
image yet, so object storage currently requires an external integration layer;
upstream support remains a future direction.

## Operational profile

- HTTP listen port: `8080`
- Runtime user: `atbox` (UID/GID configurable)
- External dependencies: MySQL + Elasticsearch + Memcached + Gearman
- Process supervision: `s6-overlay` for web roles

`atbox-cli` does not run `s6-overlay`; it bootstraps the same AtoM config and
then executes the supplied command, for example `php symfony search:populate`.
`atbox-worker` also does not run `s6-overlay`; it bootstraps config, drops to the
runtime user, and execs the worker command.

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
  ghcr.io/sevein/atbox-public:<tag>
```

Then open `http://localhost:8080`.

For local development builds from this repository, see `CONTRIBUTING.md`.

## Configuration reference

| Variable                       | Required   | Default          | Notes                                                                                           |
| ------------------------------ | ---------- | ---------------- | ----------------------------------------------------------------------------------------------- |
| `ATOM_ELASTICSEARCH_HOST`      | Yes        | none             | Elasticsearch endpoint (`host[:port]`).                                                         |
| `ATOM_GEARMAN_HOST`            | No         | `127.0.0.1:4730` | Gearman endpoint (`host[:port]`). Required for job-backed admin/worker use.                      |
| `ATOM_MEMCACHED_HOST`          | Yes        | none             | Memcached endpoint (`host[:port]`).                                                             |
| `ATOM_MYSQL_DSN`               | Yes        | none             | PDO DSN for MySQL.                                                                              |
| `ATOM_MYSQL_USERNAME`          | Yes        | none             | MySQL username.                                                                                 |
| `ATOM_MYSQL_PASSWORD`          | Yes        | none             | MySQL password.                                                                                 |
| `ATOM_NAMESPACE`               | No         | `atom`           | Convenience default used by cache/session namespace settings when they are not set directly.    |
| `ATOM_CACHE_NAMESPACE`         | No         | `ATOM_NAMESPACE` | Memcached key prefix. Set per tenant/deployment to avoid cache collisions.                      |
| `ATOM_WORKERS_KEY`             | No         | empty            | AtoM worker key. Must match across admin, CLI, and worker roles sharing a Gearman server.        |
| `ATOM_SESSION_NAME`            | No         | `ATOM_NAMESPACE` | Session cookie name. Use a distinct value when public/admin tiers should not share login state. |
| `ATOM_SESSION_COOKIE_SECURE`   | Admin only | `true`           | Set `false` only for local plain-HTTP admin testing.                                            |
| `ATOM_SESSION_COOKIE_SAMESITE` | Admin only | `lax`            | One of `strict`, `lax`, or `none`.                                                              |
| `ATOM_UPLOADS_ENABLED`         | Admin only | `false`          | Enables PHP uploads and AtoM upload UI when shared writable storage is mounted.                  |
| `ATOM_UPLOAD_LIMIT`            | Admin only | `-1`             | AtoM upload limit in gigabytes; `0` disables uploads, `-1` is unlimited.                         |
| `ATOM_PHP_POST_MAX_SIZE`       | Admin only | `512M`           | PHP `post_max_size` when uploads are enabled.                                                    |
| `ATOM_PHP_UPLOAD_MAX_FILESIZE` | Admin only | `512M`           | PHP `upload_max_filesize` when uploads are enabled.                                             |
| `ATOM_PHP_MAX_FILE_UPLOADS`    | Admin only | `20`             | PHP `max_file_uploads` when uploads are enabled.                                                 |
| `ATOM_WORKER_TYPES`            | Worker     | empty            | Optional comma-separated AtoM worker types from `gearman.yml`. Empty registers all configured types. |
| `ATOM_WORKER_ABILITIES`        | Worker     | empty            | Optional comma-separated job class abilities. Overrides worker types when set.                  |
| `ATOM_WORKER_MEMORY_LIMIT`     | Worker     | `-1`             | PHP memory limit passed to the worker process.                                                   |
| `ATOM_WORKER_MAX_JOB_COUNT`    | Worker     | empty            | Optional worker shutdown threshold after N completed jobs.                                      |
| `ATOM_WORKER_MAX_MEM_USAGE`    | Worker     | empty            | Optional worker shutdown threshold in kB RSS.                                                    |

## Helm chart

This repository includes a chart in `charts/atbox` for attached deployments
where MySQL, Elasticsearch, Memcached, and Gearman are provided externally.
Presets are included for read-only, admin-only, and public-plus-admin
topologies:

```bash
helm template atbox charts/atbox \
  --values charts/atbox/values-public-plus-admin.yaml
```

The chart exposes annotation maps on Deployments, Pods, Services, Jobs, and the
database Secret for GitOps tools such as Argo CD. Worker deployments require
existing PVCs for shared `uploads/` and `downloads/` storage.
