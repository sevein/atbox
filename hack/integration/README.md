# Integration harness

`./hack/integration/run.sh` is the local and CI entrypoint. It installs npm
dependencies from `package-lock.json`, then runs the Bats suite in
`hack/integration/tests`.

The Bats tests own the Docker Compose lifecycle and call the Playwright scripts
for browser workflows.

## Commands

- `./hack/integration/run.sh`: full integration entrypoint.
- `npm --prefix hack/integration test`: run the Bats suite directly.
- `npm --prefix hack/integration run public-smoke`: public Playwright workflow
  invoked by Bats.
- `npm --prefix hack/integration run admin-smoke`: admin Playwright workflow
  invoked by Bats.

Normally use `./hack/integration/run.sh`; the npm scripts are lower-level hooks
kept separate so Bats can name and orchestrate the browser checks.

## Layout

- `docker-compose.yml`: integration stack.
- `fixtures/`: database fixtures.
- `lib/`: shared Bash helpers.
- `tests/`: Bats test files.
- `smoke/`: Playwright browser workflows.
- `output/`: generated logs, screenshots, browser downloads, and npm cache.

## Configuration

Defaults:

- `DUMP_SQL=hack/integration/fixtures/dump.sql`
- `ATBOX_URL=http://127.0.0.1:18080/`
- `ATBOX_REPLICA_URL=http://127.0.0.1:18081/`
- `ATBOX_ADMIN_URL=http://127.0.0.1:18082/`
- `ATOM_NAMESPACE=atbox-it`
- `ADMIN_ATOM_SESSION_NAME=atbox-admin-it`
- `PROJECT_NAME=atbox-it`
- `KEEP_UP=0`

Keep the stack running for debugging:

```bash
KEEP_UP=1 ./hack/integration/run.sh
```
