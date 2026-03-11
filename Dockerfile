# =============================================================================
# AppFlowy Cloud – Home Assistant Add-on
# Target:  aarch64 (Raspberry Pi 5)
# Base:    ghcr.io/home-assistant/aarch64-base-debian:bookworm  (glibc)
#
# Multi-stage build:
#   1. build-gotrue   – compile GoTrue auth binary (static, Go)
#   2. build-pgvector – compile pgvector against Debian postgresql15-dev
#   3. build-source   – clone AppFlowy-Cloud for start.sh and assets
#   4-6. source-*     – pull official AppFlowy arm64 binaries (no Rust compile!)
#   7. Final stage    – assemble everything into the HA Debian base image
#
# Using official arm64 images avoids the 30-45 min Rust build.
# GoTrue is still compiled from source because CGO_ENABLED=0 gives a static
# binary that works on any base.
# =============================================================================

ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base-debian:bookworm
ARG APPFLOWY_VERSION=0.13.2
ARG GOTRUE_VERSION=0.8.0
ARG PGVECTOR_VERSION=v0.7.0


# ── Stage 1: Build GoTrue (static binary via CGO_ENABLED=0) ──────────────────
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


# ── Stage 2: Build pgvector against Debian postgresql16 headers ──────────────
FROM debian:bookworm-slim AS build-pgvector

ARG PGVECTOR_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        postgresql-server-dev-15 \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
        https://github.com/pgvector/pgvector.git \
        --depth 1 \
        --branch "${PGVECTOR_VERSION}" \
        /pgvector

WORKDIR /pgvector

RUN make && make install


# ── Stage 3: Clone AppFlowy-Cloud for gotrue/start.sh ────────────────────────
FROM debian:bookworm-slim AS build-source

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
        https://github.com/AppFlowy-IO/AppFlowy-Cloud.git \
        --depth 1 \
        --branch "main" \
        /appflowy_cloud_src


# ── Stage 4: Build AppFlowy Cloud Rust binaries on Debian Bookworm ───────────
# Official appflowyinc images require GLIBC_2.39 (Ubuntu 24.04 build env),
# but Debian Bookworm only has GLIBC_2.36. Compiling here produces binaries
# that link against Bookworm's glibc and run correctly in the final stage.
# This takes 30-45 min on Pi 5 but is cached by Docker on subsequent builds.
FROM rust:bookworm AS build-appflowy

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        protobuf-compiler \
        libprotobuf-dev \
        pkg-config \
        libssl-dev \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN git clone \
        https://github.com/AppFlowy-IO/AppFlowy-Cloud.git \
        --depth 1 \
        --branch main \
        .

# SQLX_OFFLINE skips live-DB query validation at compile time
ENV SQLX_OFFLINE=true

# Build only the two binaries we need (admin_frontend is Node.js, not Rust)
RUN cargo build --release \
        --bin appflowy_cloud

# ── Stage 5: Pull admin_frontend (Node.js app, no glibc issue) ───────────────
FROM appflowyinc/admin_frontend:0.13.2 AS source-admin


# ── Final stage: assemble into the HA aarch64 Debian base image ──────────────
FROM ${BUILD_FROM}

LABEL \
    io.hass.name="AppFlowy Cloud" \
    io.hass.description="Self-hosted AppFlowy Cloud server" \
    io.hass.arch="aarch64" \
    io.hass.type="addon"

# ── Runtime packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        redis-server \
        postgresql-15 \
        postgresql-client-15 \
        nginx \
        nodejs \
        curl \
        ca-certificates \
        gosu \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

# MinIO (no Debian package – download the arm64 static binary)
RUN curl -fsSL \
        https://dl.min.io/server/minio/release/linux-arm64/minio \
        -o /usr/local/bin/minio \
    && chmod +x /usr/local/bin/minio

# ── pgvector: shared object + extension SQL files ─────────────────────────────
COPY --from=build-pgvector \
    /usr/lib/postgresql/15/lib/vector.so \
    /usr/lib/postgresql/15/lib/vector.so

COPY --from=build-pgvector \
    /usr/share/postgresql/15/extension/ \
    /usr/share/postgresql/15/extension/

# ── GoTrue (auth service) ─────────────────────────────────────────────────────
RUN mkdir -p /auth

COPY --from=build-gotrue /auth-binary /auth/auth
COPY --from=build-source \
    /appflowy_cloud_src/docker/gotrue/start.sh \
    /auth/start.sh
COPY --from=build-gotrue \
    /go/src/supabase/auth/migrations \
    /auth/migrations

RUN chmod +x /auth/auth /auth/start.sh

# ── AppFlowy Cloud service binaries ───────────────────────────────────────────
RUN mkdir -p /appflowy_cloud

COPY --from=build-appflowy /app/target/release/appflowy_cloud /appflowy_cloud/appflowy_cloud

RUN chmod +x /appflowy_cloud/appflowy_cloud

# Admin frontend – Node.js app (not a Rust binary)
# Image runs: node apps/super/server.js from WORKDIR /app
RUN mkdir -p /admin_frontend
COPY --from=source-admin /app /admin_frontend

# ── PostgreSQL runtime socket directory ───────────────────────────────────────
# /var/run/postgresql is the Debian default unix socket dir for pg.
# It lives on tmpfs in containers so must be created at build time and
# recreated in run.sh before PostgreSQL starts.
RUN mkdir -p /var/run/postgresql && chown postgres:postgres /var/run/postgresql

# ── Nginx configuration ───────────────────────────────────────────────────────
COPY nginx.conf /etc/nginx/nginx.conf

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
