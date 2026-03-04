# syntax=docker/dockerfile:1.7

ARG ATOM_VERSION=2.10.1
ARG S6_OVERLAY_VERSION=3.2.0.2
ARG PHP_VERSION=8.3

FROM alpine:3.22 AS s6-downloader
ARG S6_OVERLAY_VERSION
RUN set -eux; \
    apk add --no-cache curl; \
    base_url="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    curl -LfsS -o /tmp/s6-overlay-noarch.tar.xz "${base_url}/s6-overlay-noarch.tar.xz"; \
    curl -LfsS -o /tmp/s6-overlay-x86_64.tar.xz "${base_url}/s6-overlay-x86_64.tar.xz"; \
    curl -LfsS -o /tmp/s6-overlay-aarch64.tar.xz "${base_url}/s6-overlay-aarch64.tar.xz"

FROM debian:bookworm-slim AS atom-source
ARG ATOM_VERSION
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl tar; \
    rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    mkdir -p /tmp/atom-src; \
    curl -LfsS "https://github.com/artefactual/atom/archive/refs/tags/v${ATOM_VERSION}.tar.gz" \
      | tar xz --strip-components=1 -C /tmp/atom-src; \
    mkdir -p /atom/src; \
    cp -a /tmp/atom-src/. /atom/src

FROM node:20-bookworm AS frontend-builder
WORKDIR /atom/src
COPY --from=atom-source /atom/src/package*.json /atom/src/
RUN --mount=type=cache,target=/root/.npm \
    set -eux; \
    npm ci
COPY --from=atom-source /atom/src /atom/src
RUN set -eux; \
    npm run build; \
    rm -rf node_modules

FROM debian:bookworm-slim AS runtime-base
ARG PHP_VERSION
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl lsb-release; \
    curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb; \
    dpkg -i /tmp/debsuryorg-archive-keyring.deb; \
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ bookworm main" > /etc/apt/sources.list.d/php-sury.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      iproute2 \
      nginx \
      unzip \
      xz-utils \
      php${PHP_VERSION}-fpm \
      php${PHP_VERSION}-cli \
      php${PHP_VERSION}-curl \
      php${PHP_VERSION}-gd \
      php${PHP_VERSION}-intl \
      php${PHP_VERSION}-mbstring \
      php${PHP_VERSION}-mysql \
      php${PHP_VERSION}-memcache \
      php${PHP_VERSION}-opcache \
      php${PHP_VERSION}-xsl \
      php${PHP_VERSION}-zip \
      php${PHP_VERSION}-xml \
      php${PHP_VERSION}-apcu; \
    rm -f /tmp/debsuryorg-archive-keyring.deb; \
    rm -f /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf; \
    ln -sf /usr/bin/php${PHP_VERSION} /usr/local/bin/php; \
    ln -sf /usr/sbin/php-fpm${PHP_VERSION} /usr/local/sbin/php-fpm; \
    rm -rf /var/lib/apt/lists/*

FROM runtime-base AS composer-deps
ARG ATBOX_UID=10001
ARG ATBOX_GID=10001
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_CACHE_DIR=/tmp/composer-cache
RUN set -eux; \
    groupadd --system --gid "${ATBOX_GID}" atbox; \
    useradd --system --uid "${ATBOX_UID}" --gid atbox --create-home --home-dir /home/atbox --shell /usr/sbin/nologin atbox
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
COPY --from=frontend-builder /atom/src /atom/src
WORKDIR /atom/src
RUN --mount=type=cache,target=/tmp/composer-cache \
    set -eux; \
    composer install --no-dev --prefer-dist --no-interaction --no-progress --optimize-autoloader

FROM runtime-base AS runtime
ARG S6_OVERLAY_VERSION
ARG PHP_VERSION
ARG ATBOX_UID=10001
ARG ATBOX_GID=10001
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

RUN set -eux; \
    groupadd --system --gid "${ATBOX_GID}" atbox; \
    useradd --system --uid "${ATBOX_UID}" --gid atbox --create-home --home-dir /home/atbox --shell /usr/sbin/nologin atbox

COPY --from=composer-deps /atom/src /atom/src

WORKDIR /atom/src

RUN set -eux; \
    rm -rf /var/www/html; \
    mkdir -p /run/nginx /var/log/nginx /var/lib/nginx /var/cache/nginx /tmp/atom/cache/app /tmp/atom/sessions /tmp/atom/log /atom/src/cache /atom/src/log; \
    chown -R atbox:atbox /run/nginx /var/log/nginx /var/lib/nginx /var/cache/nginx /tmp/atom /atom/src/cache /atom/src/log

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY rootfs/ /

COPY --from=s6-downloader /tmp/s6-overlay-noarch.tar.xz /tmp/
COPY --from=s6-downloader /tmp/s6-overlay-x86_64.tar.xz /tmp/s6-overlay-x86_64.tar.xz
COPY --from=s6-downloader /tmp/s6-overlay-aarch64.tar.xz /tmp/s6-overlay-aarch64.tar.xz
RUN set -eux; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
      amd64) tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz ;; \
      arm64) tar -C / -Jxpf /tmp/s6-overlay-aarch64.tar.xz ;; \
      *) echo "Unsupported runtime arch: ${arch}" >&2; exit 1 ;; \
    esac; \
    rm -f /tmp/s6-overlay-*.tar.xz; \
    chmod +x /etc/cont-init.d/10-bootstrap-atom /etc/s6-overlay/s6-rc.d/php-fpm/run /etc/s6-overlay/s6-rc.d/nginx/run /usr/local/bin/atbox-bootstrap.php

EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/init"]
