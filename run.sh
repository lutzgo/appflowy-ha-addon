#!/usr/bin/env bashio
# =============================================================================
# AppFlowy Cloud – Home Assistant Add-on startup script
#
# Startup order (each step waits for the previous service to be ready):
#   1. PostgreSQL        – initialise data directory (once), start daemon
#   2. Role setup        – set postgres password + CREATE supabase_auth_admin
#   3. Redis             – start daemon
#   4. MinIO             – start object storage server
#   5. GoTrue (auth)     – run migrations + start auth API on :9999
#   6. AppFlowy Cloud    – main API server on :8000
#   7. Admin Frontend    – management UI on :3000
#   8. AppFlowy Worker   – background job processor
#   9. Nginx             – reverse proxy on :8087  (foreground – keeps PID 1)
#
# CRITICAL FIX: The 'supabase_auth_admin' PostgreSQL role MUST be created
# BEFORE GoTrue starts.  GoTrue's DATABASE_URL uses this role as the login
# user and crashes silently if the role does not exist.
#
# All logs are written to /data/logs/<service>.log
# Initialisation is idempotent: safe to restart the add-on at any time.
# =============================================================================

set -e

readonly LOG_DIR=/data/logs
readonly PG_DATA=/data/postgresql
readonly MINIO_DATA=/data/minio

# ── Helper: wait for a TCP port to become available ──────────────────────────
wait_for_port() {
    local host="$1"
    local port="$2"
    local max_tries="${3:-30}"
    local name="${4:-service}"
    local tries=0

    bashio::log.info "Waiting for ${name} on port ${port} …"
    while [ "${tries}" -lt "${max_tries}" ]; do
        if timeout 1 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
            bashio::log.info "${name} is ready (port ${port})"
            return 0
        fi
        tries=$(( tries + 1 ))
        sleep 1
    done

    bashio::log.error "${name} did not become ready on port ${port} after ${max_tries}s"
    bashio::log.error "Check ${LOG_DIR}/${name}.log for details"
    exit 1
}

# ── 1. Read add-on configuration from HA options ─────────────────────────────
bashio::log.info "Reading add-on configuration …"

SECRET="$(bashio::config 'SECRET')"
ADMIN_EMAIL="$(bashio::config 'ADMIN_EMAIL')"
ADMIN_PASSWORD="$(bashio::config 'ADMIN_PASSWORD')"
PUBLIC_URL="$(bashio::config 'PUBLIC_URL')"
SMTP_HOST="$(bashio::config 'SMTP_HOST')"
SMTP_PORT="$(bashio::config 'SMTP_PORT')"
SMTP_USER="$(bashio::config 'SMTP_USER')"
SMTP_PASSWORD="$(bashio::config 'SMTP_PASSWORD')"

# ── 2. Export runtime environment variables ───────────────────────────────────
# GoTrue / auth
export GOTRUE_JWT_SECRET="${SECRET}"
export GOTRUE_ADMIN_EMAIL="${ADMIN_EMAIL}"
export GOTRUE_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
export GOTRUE_JWT_ADMIN_GROUP_NAME="supabase_admin"
export GOTRUE_SMTP_HOST="${SMTP_HOST}"
export GOTRUE_SMTP_PORT="${SMTP_PORT}"
export GOTRUE_SMTP_USER="${SMTP_USER}"
export GOTRUE_SMTP_PASS="${SMTP_PASSWORD}"
export GOTRUE_SMTP_ADMIN_EMAIL="${SMTP_USER}"
export GOTRUE_MAILER_AUTOCONFIRM="false"
export GOTRUE_SITE_URL="${PUBLIC_URL}"
export API_EXTERNAL_URL="${PUBLIC_URL}/gotrue"

# AppFlowy Cloud
export APPFLOWY_GOTRUE_JWT_SECRET="${SECRET}"
export APPFLOWY_GOTRUE_ADMIN_EMAIL="${ADMIN_EMAIL}"
export APPFLOWY_GOTRUE_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
export APPFLOWY_GOTRUE_EXT_URL="${PUBLIC_URL}/gotrue"
export AF_GOTRUE_URL="${PUBLIC_URL}/gotrue"
export APPFLOWY_WEB_URL="${PUBLIC_URL}"
export APPFLOWY_S3_PRESIGNED_URL_ENDPOINT="${PUBLIC_URL}/minio-api"

# MinIO root credentials (must match APPFLOWY_S3_ACCESS_KEY / SECRET_KEY)
export MINIO_ROOT_USER="minioadmin"
export MINIO_ROOT_PASSWORD="minioadmin"

# ── 3. Create log directory ───────────────────────────────────────────────────
bashio::log.info "Setting up log directory at ${LOG_DIR} …"
mkdir -p "${LOG_DIR}"

# ── 4. PostgreSQL: initialise data directory (once) ──────────────────────────
if [ ! -d "${PG_DATA}" ]; then
    bashio::log.info "Initialising PostgreSQL data directory …"
    mkdir -p "${PG_DATA}"
    chown postgres:postgres "${PG_DATA}"
    su-exec postgres initdb \
        -D "${PG_DATA}" \
        --auth-local=trust \
        --auth-host=md5 \
        >> "${LOG_DIR}/postgres.log" 2>&1
    bashio::log.info "PostgreSQL data directory initialised"
fi

bashio::log.info "Starting PostgreSQL …"
su-exec postgres pg_ctl \
    start \
    -D "${PG_DATA}" \
    -l "${LOG_DIR}/postgres.log" \
    -w   # wait until server is ready before returning
bashio::log.info "PostgreSQL started"

# ── 5. PostgreSQL: configure roles and passwords (idempotent) ─────────────────

# Set the 'postgres' superuser password so AppFlowy Cloud can authenticate.
# This is idempotent: running ALTER USER again with the same password is fine.
bashio::log.info "Setting postgres superuser password …"
su-exec postgres psql -c \
    "ALTER USER postgres WITH PASSWORD 'password';" \
    >> "${LOG_DIR}/postgres.log" 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# CRITICAL FIX: Create the 'supabase_auth_admin' role BEFORE GoTrue starts.
#
# GoTrue's DATABASE_URL is configured as:
#   postgres://supabase_auth_admin:root@localhost:5432/postgres
#
# GoTrue connects as this role to run schema migrations and serve auth
# requests.  Without this role, GoTrue crashes silently at startup with no
# useful error message in the log.
#
# The role needs SUPERUSER + LOGIN so it can create the 'auth' schema and
# manage objects within it.
# ─────────────────────────────────────────────────────────────────────────────
if su-exec postgres psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='supabase_auth_admin';" \
    2>/dev/null | grep -q 1; then
    bashio::log.info "PostgreSQL role 'supabase_auth_admin' already exists – skipping"
else
    bashio::log.info "Creating PostgreSQL role 'supabase_auth_admin' …"
    su-exec postgres psql -c \
        "CREATE ROLE supabase_auth_admin WITH SUPERUSER LOGIN PASSWORD 'root';" \
        >> "${LOG_DIR}/postgres.log" 2>&1
    bashio::log.info "Role 'supabase_auth_admin' created"
fi

# ── 6. Redis ──────────────────────────────────────────────────────────────────
bashio::log.info "Starting Redis …"
redis-server \
    --daemonize no \
    --loglevel notice \
    >> "${LOG_DIR}/redis.log" 2>&1 &

wait_for_port "localhost" "6379" 15 "redis"

# ── 7. MinIO ──────────────────────────────────────────────────────────────────
bashio::log.info "Starting MinIO …"
mkdir -p "${MINIO_DATA}"

minio server "${MINIO_DATA}" \
    --console-address ":9001" \
    >> "${LOG_DIR}/minio.log" 2>&1 &

wait_for_port "localhost" "9000" 30 "minio"

# ── 8. GoTrue (auth service) ──────────────────────────────────────────────────
# start.sh (from AppFlowy-Cloud) runs: auth migrate → create admin user → auth
# It must run AFTER supabase_auth_admin role exists (step 5 above).
bashio::log.info "Starting GoTrue auth service …"
cd /auth
./start.sh >> "${LOG_DIR}/auth.log" 2>&1 &

wait_for_port "localhost" "9999" 60 "auth"

# ── 9. AppFlowy Cloud (main API) ──────────────────────────────────────────────
bashio::log.info "Starting AppFlowy Cloud …"
cd /appflowy_cloud
./appflowy_cloud >> "${LOG_DIR}/appflowy_cloud.log" 2>&1 &

wait_for_port "localhost" "8000" 60 "appflowy_cloud"

# ── 10. Admin Frontend ────────────────────────────────────────────────────────
# Override PORT=9999 (set for GoTrue) – admin_frontend listens on 3000.
bashio::log.info "Starting Admin Frontend …"
PORT=3000 ./admin_frontend >> "${LOG_DIR}/admin_frontend.log" 2>&1 &

# ── 11. AppFlowy Worker ───────────────────────────────────────────────────────
bashio::log.info "Starting AppFlowy Worker …"
./appflowy_worker >> "${LOG_DIR}/appflowy_worker.log" 2>&1 &

# ── 12. Nginx (foreground – keeps the container alive) ────────────────────────
bashio::log.info "All services started. Starting Nginx on port 8087 …"
nginx -g "daemon off;"
