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
  -e ATOM_MYSQL_DSN='mysql:host=mysql;dbname=atom;charset=utf8mb4' \
  -e ATOM_MYSQL_USERNAME=atom \
  -e ATOM_MYSQL_PASSWORD='replace-me' \
  atbox:dev
```

Open `http://localhost:8080`.

Use `--network <name>` if MySQL/Elasticsearch are running in another Docker network.

## Quick debug shell

```bash
docker run --rm -it --entrypoint sh atbox:dev
```
