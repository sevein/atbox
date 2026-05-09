# Contributing

This repository builds and tests a small AtoM container image family:

- `readonly-runtime`: public read-only web runtime, published as
  `ghcr.io/sevein/atbox-public`.
- `admin-runtime`: authenticated metadata-editing web runtime, published as
  `ghcr.io/sevein/atbox-admin`.
- `cli-runtime`: one-shot lifecycle/runtime CLI image, published as
  `ghcr.io/sevein/atbox-cli`.
- `worker-runtime`: long-running AtoM Gearman worker image, published as
  `ghcr.io/sevein/atbox-worker`.

Keep changes scoped to those roles. The readonly image should remain safe for
public browsing, while admin, CLI, and worker behavior should stay isolated in
their own targets.

## Requirements

- Docker with Buildx and Compose v2.
- Node.js/npm for integration browser checks.
- Helm 3 for chart validation.
- helm-unittest plugin for chart unit tests.
- kubeconform for rendered Kubernetes manifest validation.
- GitHub CLI only if triggering releases from the command line.

The integration runner installs npm dependencies from
`hack/integration/package-lock.json` and stores generated browser/cache/output
files under `hack/integration/output/`.

## Repository layout

- `Dockerfile`: shared AtoM build layers and role-specific runtime targets.
- `rootfs/base/`: shared runtime filesystem additions.
- `rootfs/readonly/`: readonly-only filesystem additions.
- `rootfs/admin/`: admin-only filesystem additions.
- `rootfs/cli/`: CLI-only filesystem additions.
- `rootfs/worker/`: worker-only filesystem additions.
- `nginx/`: readonly and admin nginx configs.
- `hack/integration/`: Docker Compose integration suite.
- `charts/atbox/`: Helm chart and preset values files.
- `.github/workflows/`: CI validation and manual release workflow.

## Local image builds

Build the default readonly image for your host architecture:

```bash
docker buildx build --target readonly-runtime -t atbox-public:dev --load .
```

Build all role images explicitly:

```bash
docker buildx build --target readonly-runtime -t atbox-public:dev --load .
docker buildx build --target admin-runtime -t atbox-admin:dev --load .
docker buildx build --target cli-runtime -t atbox-cli:dev --load .
docker buildx build --target worker-runtime -t atbox-worker:dev --load .
```

Build for a specific platform when checking multi-architecture behavior:

```bash
docker buildx build --platform linux/amd64 --target readonly-runtime -t atbox-public:amd64 --load .
docker buildx build --platform linux/arm64 --target readonly-runtime -t atbox-public:arm64 --load .
```

Use `--check` before heavier builds when changing the Dockerfile:

```bash
docker buildx build --target readonly-runtime --check .
docker buildx build --target admin-runtime --check .
docker buildx build --target cli-runtime --check .
docker buildx build --target worker-runtime --check .
```

## Local runtime checks

Run the readonly image against external MySQL, Elasticsearch, and Memcached:

```bash
docker run --rm -p 8080:8080 \
  -e ATOM_ELASTICSEARCH_HOST=elasticsearch:9200 \
  -e ATOM_MEMCACHED_HOST=memcached:11211 \
  -e ATOM_NAMESPACE=atbox-dev \
  -e ATOM_MYSQL_DSN='mysql:host=mysql;dbname=atom;charset=utf8mb4' \
  -e ATOM_MYSQL_USERNAME=atom \
  -e ATOM_MYSQL_PASSWORD='replace-me' \
  atbox-public:dev
```

Use `--network <name>` when dependencies are running in a Docker network.

Open a shell for quick inspection:

```bash
docker run --rm -it --entrypoint sh atbox-public:dev
```

Check the CLI image boots and runs a PHP command:

```bash
docker run --rm \
  -e ATOM_ELASTICSEARCH_HOST=elasticsearch:9200 \
  -e ATOM_MEMCACHED_HOST=memcached:11211 \
  -e ATOM_MYSQL_DSN='mysql:host=mysql;dbname=atom;charset=utf8mb4' \
  -e ATOM_MYSQL_USERNAME=atom \
  -e ATOM_MYSQL_PASSWORD='replace-me' \
  atbox-cli:dev php -r 'echo "cli ok\n";'
```

## Integration tests

Run the full integration suite:

```bash
./hack/integration/run.sh
```

The suite is implemented with Bats tests in `hack/integration/tests`. Shared
helpers live in `hack/integration/lib`, and Playwright browser workflows live in
`hack/integration/smoke`.

By default the stack is cleaned up after the run. Keep it up for debugging:

```bash
KEEP_UP=1 ./hack/integration/run.sh
```

Then inspect services with:

```bash
docker compose -p atbox-it -f hack/integration/docker-compose.yml ps
docker compose -p atbox-it -f hack/integration/docker-compose.yml logs --tail=100 atbox_admin
```

Clean up manually after a kept-up run:

```bash
docker compose -p atbox-it -f hack/integration/docker-compose.yml down -v --remove-orphans
```

## Helm chart checks

Run chart unit tests:

```bash
helm unittest charts/atbox
```

Lint all supported presets:

```bash
helm lint charts/atbox --values charts/atbox/values-readonly-attached.yaml
helm lint charts/atbox --values charts/atbox/values-admin-attached.yaml
helm lint charts/atbox --values charts/atbox/values-public-plus-admin.yaml
```

Render all supported presets:

```bash
helm template atbox charts/atbox --values charts/atbox/values-readonly-attached.yaml
helm template atbox charts/atbox --values charts/atbox/values-admin-attached.yaml
helm template atbox charts/atbox --values charts/atbox/values-public-plus-admin.yaml
```

Validate rendered presets against Kubernetes schemas:

```bash
./hack/helm-kubeconform.sh
```

When changing chart templates, prefer explicit values and predictable
labels/selectors over clever template indirection.

## Documentation checks

Before handing off a change, run:

```bash
git diff --check
```

Update `README.md`, `CONTRIBUTING.md`, chart values comments, and integration
docs when behavior changes. Keep `AGENTS.md` short and command-oriented.

## Best practices for this repo

- Preserve role separation. Do not make admin write behavior a runtime switch on
  the public readonly image.
- Keep the Dockerfile targets buildable independently.
- Prefer immutable image behavior plus explicit environment variables over
  startup-time package installs or source edits.
- Keep public readonly containers limited to `GET` and `HEAD` unless the project
  intentionally expands that support.
- Keep admin and worker write behavior paired with explicit Gearman and shared
  upload/download storage configuration.
- Keep cache and session names explicit when public/admin tiers share Memcached.
- Validate Helm changes with `helm unittest`, `helm lint`, `helm template`, and
  `./hack/helm-kubeconform.sh`.
- Add or update integration coverage when changing role behavior, bootstrap
  config, nginx method policy, or release artifacts.
- Avoid committing generated integration output, npm caches, Playwright
  browsers, or local Docker artifacts.

## Release process

Image and chart releases are driven by the manual GitHub Actions workflow in
`.github/workflows/release.yml`. Images and the Helm chart can be released
together or independently.

Trigger images and chart together:

```bash
gh workflow run release.yml \
  -f image_tag=2.10.1-dev1 \
  -f atom_version=2.10.1 \
  -f chart_version=0.1.0 \
  -f release_images=true \
  -f release_chart=true
```

Release only the container images:

```bash
gh workflow run release.yml \
  -f image_tag=2.10.1-dev1 \
  -f atom_version=2.10.1 \
  -f release_images=true \
  -f release_chart=false
```

Release only the Helm chart:

```bash
gh workflow run release.yml \
  -f image_tag=2.10.1-dev1 \
  -f chart_version=0.1.0 \
  -f release_images=false \
  -f release_chart=true
```

When `release_images=true`, the workflow builds and publishes multi-architecture
manifests for:

- `ghcr.io/sevein/atbox-public:<image_tag>`
- `ghcr.io/sevein/atbox-admin:<image_tag>`
- `ghcr.io/sevein/atbox-cli:<image_tag>`
- `ghcr.io/sevein/atbox-worker:<image_tag>`

When `release_chart=true`, it packages `charts/atbox` with the supplied chart
version and publishes it to GHCR as an OCI Helm artifact. The chart `appVersion`
is set from `image_tag`; chart-only releases therefore assume that the
referenced image tag already exists or is intentionally being documented ahead
of image publication.

Before triggering a release, make sure:

- `./hack/integration/run.sh` passes.
- Helm lint/template checks pass for all preset values files.
- `image_tag` matches the intended AtoM/application image version.
- `atom_version` is set when publishing images.
- `chart_version` follows SemVer and is not already published when publishing
  the chart.
- The release notes identify the AtoM version, image tag, chart version, and any
  migration or deployment notes.
