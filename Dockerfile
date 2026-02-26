# syntax=docker/dockerfile:1.7

ARG ATOM_VERSION=2.10.1
ARG S6_OVERLAY_VERSION=3.2.0.2

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
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    mkdir -p /tmp/atom-src; \
    curl -LfsS "https://github.com/artefactual/atom/archive/refs/tags/v${ATOM_VERSION}.tar.gz" \
      | tar xz --strip-components=1 -C /tmp/atom-src; \
    mkdir -p /atom/src; \
    cp -a /tmp/atom-src/. /atom/src

FROM node:20-bookworm AS frontend-builder
COPY --from=atom-source /atom/src /atom/src
WORKDIR /atom/src
RUN set -eux; \
    npm ci; \
    npm run build; \
    rm -rf node_modules

FROM php:8.3-fpm-bookworm AS runtime
ARG S6_OVERLAY_VERSION
ENV COMPOSER_ALLOW_SUPERUSER=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      iproute2 \
      nginx \
      unzip \
      git \
      libicu-dev \
      libonig-dev \
      libxml2-dev \
      libxslt1-dev \
      libzip-dev \
      zlib1g-dev \
      libpng-dev \
      libjpeg62-turbo-dev \
      libfreetype6-dev \
      autoconf \
      g++ \
      make \
      pkg-config; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      gettext \
      intl \
      mbstring \
      mysqli \
      opcache \
      pcntl \
      pdo_mysql \
      xsl \
      zip \
      gd; \
    pecl install apcu; \
    docker-php-ext-enable apcu; \
    apt-get purge -y --auto-remove autoconf g++ make pkg-config; \
    rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
COPY --from=frontend-builder /atom/src /atom/src

WORKDIR /atom/src

RUN set -eux; \
    composer install --no-dev --prefer-dist --no-interaction; \
    rm -rf /var/www/html; \
    mkdir -p /run/nginx /var/log/nginx

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
    chmod +x /etc/cont-init.d/10-bootstrap-atom /etc/services.d/php-fpm/run /etc/services.d/nginx/run /usr/local/bin/atbox-bootstrap.php

EXPOSE 80
STOPSIGNAL SIGTERM
ENTRYPOINT ["/init"]
