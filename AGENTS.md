# AGENTS.md

## Project overview

- Builds AtoM container images for readonly web, admin web, CLI, and worker roles.
- Runtime roles are Dockerfile targets: `readonly-runtime`, `admin-runtime`,
  `cli-runtime`, `worker-runtime`.
- Root filesystem additions are split across `rootfs/base`, `rootfs/readonly`,
  `rootfs/admin`, `rootfs/cli`, and `rootfs/worker`.
- Helm chart lives in `charts/atbox`.
- Integration stack lives in `hack/integration/`.

## Common commands

- Dockerfile checks:
  - `docker buildx build --target readonly-runtime --check .`
  - `docker buildx build --target admin-runtime --check .`
  - `docker buildx build --target cli-runtime --check .`
  - `docker buildx build --target worker-runtime --check .`
- Full integration suite: `./hack/integration/run.sh`
- Integration assertions live in `hack/integration/tests/*.bats`.
- Keep failed integration stack up: `KEEP_UP=1 ./hack/integration/run.sh`
- Helm unit tests: `helm unittest charts/atbox`
- Helm lint:
  - `helm lint charts/atbox --values charts/atbox/values-readonly-attached.yaml`
  - `helm lint charts/atbox --values charts/atbox/values-admin-attached.yaml`
  - `helm lint charts/atbox --values charts/atbox/values-public-plus-admin.yaml`
- Rendered chart validation: `./hack/helm-kubeconform.sh`
- Whitespace check: `git diff --check`

## Conventions

- Keep readonly, admin, CLI, and worker behavior isolated by image target.
- Do not turn admin write behavior into a runtime switch on the public image.
- Keep public readonly nginx limited to `GET` and `HEAD`.
- Use explicit env vars for cache/session behavior.
- Update integration coverage when changing role behavior, bootstrap config,
  nginx policy, Helm output, or release artifacts.
- Do not commit generated `hack/integration/output`,
  `hack/integration/node_modules`, Playwright browser caches, or local build
  artifacts.

## Release notes

- Manual release workflow: `.github/workflows/release.yml`.
- Select artifacts with `release_images` and `release_chart`.
- `image_tag` is always required.
- `atom_version` is required when `release_images=true`.
- `chart_version` is required when `release_chart=true`.
- Published images: `ghcr.io/sevein/atbox`, `ghcr.io/sevein/atbox-admin`,
  `ghcr.io/sevein/atbox-cli`, `ghcr.io/sevein/atbox-worker`.
- Helm chart is published as an OCI artifact from `charts/atbox`.
