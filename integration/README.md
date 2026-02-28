# Integration harness

This folder provides a repeatable end-to-end smoke environment for `atbox`
using:

- `mysql:8.4.8-oraclelinux9`
- `docker.elastic.co/elasticsearch/elasticsearch-oss:7.10.2`
- local `atbox` image built from this repository

## What it validates

- stack boot order and dependency readiness
- SQL dump import into MySQL
- AtoM page load over HTTP
- browser-level smoke check via Playwright Node script (`npm run smoke`)
- Elasticsearch index bootstrap (`php symfony search:populate`)
- zero-result search query path (confirms search requests hit Elasticsearch
  without backend errors)
- runtime hardening guardrails (`no-new-privileges`, dropped Linux capability
  `NET_RAW`)
- rootless runtime execution checks for `nginx` and `php-fpm`
- operational log capture in container logs via native stdout/stderr (php-fpm
  readiness + service startup logs)
- absence of tail-based log forwarder processes
- absence of known permission/cache fatal errors

## Run

```bash
chmod +x integration/run.sh
integration/run.sh
```

The harness installs pinned Playwright dependencies via `npm ci` inside
`integration/` before browser checks and runs
`integration/smoke/playwright-smoke.mjs`.

Defaults:

- `DUMP_SQL=integration/fixtures/dump.sql`
- `ATBOX_URL=http://127.0.0.1:18080/`
- `PROJECT_NAME=atbox-it`
- `KEEP_UP=0` (auto teardown)

## Useful overrides

```bash
DUMP_SQL=/path/to/dump.sql KEEP_UP=1 integration/run.sh
```

When `KEEP_UP=1`, the stack stays running for manual debugging.
