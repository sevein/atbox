# Contributing

This file covers local development/testing commands for this repository.

## Build a local image

Build for a specific architecture with `buildx`:

```bash
docker buildx build --platform linux/arm64 -t atbox:dev --load .
```

## Run local image for testing

```bash
docker run --rm -p 8080:8080 \
  -e ATOM_ELASTICSEARCH_HOST=elasticsearch:9200 \
  -e ATOM_MEMCACHED_HOST=memcached:11211 \
  -e ATOM_NAMESPACE=atbox-dev \
  -e ATOM_MYSQL_DSN='mysql:host=mysql;dbname=atom;charset=utf8mb4' \
  -e ATOM_MYSQL_USERNAME=atom \
  -e ATOM_MYSQL_PASSWORD='replace-me' \
  atbox:dev
```

Open `http://localhost:8080`.

Use `--network <name>` if MySQL/Elasticsearch are running in another Docker
network.

## Quick debug shell

```bash
docker run --rm -it --entrypoint sh atbox:dev
```

## Release process

Image releases are driven by a GitHub Actions workflow in
`.github/workflows/release.yml` and are triggered manually.

You can trigger it from GitHub CLI with:

```bash
gh workflow run release.yml \
  -f image_tag=2.10.1-dev1 \
  -f atom_version=2.10.1
```
