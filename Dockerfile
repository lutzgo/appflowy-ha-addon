# =============================================================================
# AppFlowy Cloud – Home Assistant Add-on
# Target:  aarch64 (Raspberry Pi 5)
# Base:    ghcr.io/home-assistant/aarch64-base:3.20  (Alpine 3.20)
#
# Multi-stage build:
#   1. build-gotrue   – compile GoTrue auth binary from AppFlowy-IO/auth
#   2. build-pgvector – compile pgvector extension for PostgreSQL 16
#   3. build-source   – clone AppFlowy-Cloud for migrations, assets, start.sh
#   4. build-appflowy – compile Rust binaries (appflowy_cloud, admin_frontend,
#                       appflowy_worker) from AppFlowy-Cloud source
#   5. Final stage    – assemble all artefacts into the HA base image
#
# NOTE: The Rust build stage is slow (~30-45 min on Pi 5).
#       It only runs when the source changes; Docker layer caching helps.
# =============================================================================

ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.20
ARG APPFLOWY_CLOUD_VERSION=main
ARG GOTRUE_VERSION=0.8.0
ARG PGVECTOR_VERSION=v0.7.0

# ── Stage 1: Build GoTrue (auth service) ─────────────────────────────────────
FROM golang:1.22-alpine3.20 AS build-gotrue

ARG GOTRUE_VERSION

RUN apk add --no-cache git make

WORKDIR /go/src/supabase/auth

RUN git clone \
        https://github.com/AppFlowy-IO/auth.git \
        --depth 1 \
        --branch "${GOTRUE_VERSION}" \
        . \
    && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
       go build -ldflags="-s -w" -o /auth-binary .


# ── Stage 2: Build pgvector extension for PostgreSQL 16 ──────────────────────
FROM alpine:3.20 AS build-pgvector

ARG PGVECTOR_VERSION

RUN apk add --no-cache build-base postgresql16-dev git

RUN git clone \
        https://github.com/pgvector/pgvector.git \
        --depth 1 \
        --branch "${PGVECTOR_VERSION}" \
        /pgvector

WORKDIR /pgvector

# PG_CONFIG points to the Alpine postgresql16 binary
RUN make PG_CONFIG=/usr/bin/pg_config \
    && make install PG_CONFIG=/usr/bin/pg_config


# ── Stage 3: Clone AppFlowy-Cloud for migrations, assets, gotrue/start.sh ────
FROM alpine:3.20 AS build-source

ARG APPFLOWY_CLOUD_VERSION

RUN apk add --no-cache git

RUN git clone \
        https://github.com/AppFlowy-IO/AppFlowy-Cloud.git \
        --depth 1 \
        --branch "${APPFLOWY_CLOUD_VERSION}" \
        /appflowy_cloud_src


# ── Stage 4: Build AppFlowy Cloud Rust binaries ───────────────────────────────
# Builds three binaries from the AppFlowy-Cloud workspace using the musl
# toolchain that is native to Alpine, producing statically-linked executables.
FROM rust:alpine3.20 AS build-appflowy

ARG APPFLOWY_CLOUD_VERSION

# Build dependencies
RUN apk add --no-cache \
        build-base \
        musl-dev \
        openssl-dev \
        openssl-libs-static \
        pkgconf \
        protobuf-dev \
        git \
        perl \
        curl

WORKDIR /app

# Clone source (reuse cached clone if only rebuild is needed)
RUN git clone \
        https://github.com/AppFlowy-IO/AppFlowy-Cloud.git \
        --depth 1 \
        --branch "${APPFLOWY_CLOUD_VERSION}" \
        .

# Use vendored/offline sqlx to avoid needing a live database at build time
ENV SQLX_OFFLINE=true
# Static OpenSSL linking via openssl-sys vendored feature
ENV OPENSSL_STATIC=1
ENV OPENSSL_LIB_DIR=/usr/lib
ENV OPENSSL_INCLUDE_DIR=/usr/include

# Build only the three required binaries (avoids building the entire workspace)
RUN cargo build --release \
        --bin appflowy_cloud \
        --bin admin_frontend \
        --bin appflowy_worker


# ── Final stage: assemble everything into the HA aarch64 base image ──────────
FROM ${BUILD_FROM}

LABEL \
    io.hass.name="AppFlowy Cloud" \
    io.hass.description="Self-hosted AppFlowy Cloud server" \
    io.hass.arch="aarch64" \
    io.hass.type="addon"

# ── Runtime packages ──────────────────────────────────────────────────────────
RUN apk add --no-cache \
        redis \
        postgresql16 \
        postgresql16-contrib \
        minio \
        nginx \
        curl \
        bash \
        su-exec

# ── pgvector: copy shared object + extension SQL files ───────────────────────
COPY --from=build-pgvector \
    /usr/lib/postgresql16/vector.so \
    /usr/lib/postgresql16/vector.so

# bitcode is optional (only needed for JIT); copy if present
COPY --from=build-pgvector \
    /usr/share/postgresql16/extension/ \
    /usr/share/postgresql16/extension/

# ── GoTrue (auth service) ─────────────────────────────────────────────────────
RUN mkdir -p /auth

# Compiled binary (renamed to 'auth' to match start.sh's ./auth invocation)
COPY --from=build-gotrue /auth-binary /auth/auth

# start.sh from AppFlowy-Cloud (runs migrate + admin user creation + binary)
COPY --from=build-source \
    /appflowy_cloud_src/docker/gotrue/start.sh \
    /auth/start.sh

# Migration SQL files (GoTrue needs these to initialise the auth schema)
COPY --from=build-gotrue \
    /go/src/supabase/auth/migrations \
    /auth/migrations

RUN chmod +x /auth/auth /auth/start.sh

# ── AppFlowy Cloud service binaries ──────────────────────────────────────────
RUN mkdir -p /appflowy_cloud

COPY --from=build-appflowy \
    /app/target/release/appflowy_cloud \
    /appflowy_cloud/appflowy_cloud

COPY --from=build-appflowy \
    /app/target/release/admin_frontend \
    /appflowy_cloud/admin_frontend

COPY --from=build-appflowy \
    /app/target/release/appflowy_worker \
    /appflowy_cloud/appflowy_worker

RUN chmod +x \
    /appflowy_cloud/appflowy_cloud \
    /appflowy_cloud/admin_frontend \
    /appflowy_cloud/appflowy_worker

# Admin frontend static assets (HTML/CSS/JS templates served by the binary)
COPY --from=build-source \
    /appflowy_cloud_src/admin_frontend/assets \
    /appflowy_cloud/assets

# Database migration SQL files
COPY --from=build-source \
    /appflowy_cloud_src/migrations \
    /appflowy_cloud/migrations

# ── PostgreSQL runtime setup ──────────────────────────────────────────────────
# The actual data directory lives in /data/postgresql (persistent HA volume).
# Only the runtime socket directory is needed here.
RUN mkdir -p /run/postgresql \
    && chown postgres:postgres /run/postgresql

# ── Nginx configuration ───────────────────────────────────────────────────────
COPY nginx.conf /etc/nginx/nginx.conf

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
