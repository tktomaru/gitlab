#!/usr/bin/env bash
#
# GitLab CE Docker Entrypoint
# Handles configuration, database initialization, and process startup
#
set -euo pipefail

###############################################################################
# Default environment variables
###############################################################################
: "${GITLAB_HOST:=localhost}"
: "${GITLAB_PORT:=80}"
: "${GITLAB_HTTPS:=false}"
: "${GITLAB_RELATIVE_URL_ROOT:=}"
: "${GITLAB_SSH_PORT:=22}"

: "${DB_ADAPTER:=postgresql}"
: "${DB_HOST:=postgresql}"
: "${DB_PORT:=5432}"
: "${DB_USER:=gitlab}"
: "${DB_PASS:=gitlab}"
: "${DB_NAME:=gitlabhq_production}"

: "${REDIS_HOST:=redis}"
: "${REDIS_PORT:=6379}"

: "${GITLAB_ROOT_PASSWORD:=ChangeMe123!}"
: "${GITLAB_ROOT_EMAIL:=admin@local.host}"

: "${GITLAB_SECRETS_DB_KEY_BASE:=$(openssl rand -hex 64)}"
: "${GITLAB_SECRETS_SECRET_KEY_BASE:=$(openssl rand -hex 64)}"
: "${GITLAB_SECRETS_OTP_KEY_BASE:=$(openssl rand -hex 64)}"

: "${PUMA_WORKERS:=2}"
: "${PUMA_MIN_THREADS:=1}"
: "${PUMA_MAX_THREADS:=4}"

GITLAB_DIR="/home/git/gitlab"
GITALY_DIR="/home/git/gitaly"
INIT_MARKER="/home/git/data/.gitlab-initialized"

###############################################################################
# Wait for services
###############################################################################
wait_for_service() {
    local host="$1"
    local port="$2"
    local name="$3"
    local max_attempts=60
    local attempt=0

    echo "Waiting for ${name} at ${host}:${port}..."
    while ! nc -z "${host}" "${port}" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ ${attempt} -ge ${max_attempts} ]]; then
            echo "ERROR: ${name} at ${host}:${port} not available after ${max_attempts} attempts."
            exit 1
        fi
        echo "  Attempt ${attempt}/${max_attempts} — waiting..."
        sleep 2
    done
    echo "${name} is available."
}

echo "=== GitLab CE Docker Entrypoint ==="

wait_for_service "${DB_HOST}" "${DB_PORT}" "PostgreSQL"
wait_for_service "${REDIS_HOST}" "${REDIS_PORT}" "Redis"

###############################################################################
# Generate configuration files from environment variables
###############################################################################
echo "Generating configuration files..."

# --- database.yml (complete rewrite, main + ci sections) ---
cat > "${GITLAB_DIR}/config/database.yml" <<DBEOF
production:
  main:
    adapter: ${DB_ADAPTER}
    encoding: unicode
    database: ${DB_NAME}
    host: ${DB_HOST}
    port: ${DB_PORT}
    username: ${DB_USER}
    password: "${DB_PASS}"
    prepared_statements: false
  ci:
    adapter: ${DB_ADAPTER}
    encoding: unicode
    database: ${DB_NAME}
    host: ${DB_HOST}
    port: ${DB_PORT}
    username: ${DB_USER}
    password: "${DB_PASS}"
    prepared_statements: false
    database_tasks: false
DBEOF
chown git:git "${GITLAB_DIR}/config/database.yml"
chmod 0600 "${GITLAB_DIR}/config/database.yml"

# --- resque.yml (Redis connection) ---
cat > "${GITLAB_DIR}/config/resque.yml" <<RESQUE_EOF
production:
  url: redis://${REDIS_HOST}:${REDIS_PORT}
RESQUE_EOF
chown git:git "${GITLAB_DIR}/config/resque.yml"

# --- cable.yml (Action Cable / Redis) ---
cat > "${GITLAB_DIR}/config/cable.yml" <<CABLE_EOF
production:
  adapter: redis
  url: redis://${REDIS_HOST}:${REDIS_PORT}
CABLE_EOF
chown git:git "${GITLAB_DIR}/config/cable.yml"

# --- redis.cache.yml ---
cat > "${GITLAB_DIR}/config/redis.cache.yml" <<RCACHE_EOF
production:
  url: redis://${REDIS_HOST}:${REDIS_PORT}/10
RCACHE_EOF
chown git:git "${GITLAB_DIR}/config/redis.cache.yml"

# --- redis.queues.yml ---
cat > "${GITLAB_DIR}/config/redis.queues.yml" <<RQUEUES_EOF
production:
  url: redis://${REDIS_HOST}:${REDIS_PORT}/11
RQUEUES_EOF
chown git:git "${GITLAB_DIR}/config/redis.queues.yml"

# --- redis.shared_state.yml ---
cat > "${GITLAB_DIR}/config/redis.shared_state.yml" <<RSHARED_EOF
production:
  url: redis://${REDIS_HOST}:${REDIS_PORT}/12
RSHARED_EOF
chown git:git "${GITLAB_DIR}/config/redis.shared_state.yml"

# --- gitlab.yml (key settings via sed) ---
cd "${GITLAB_DIR}"
cp config/gitlab.yml.example config/gitlab.yml 2>/dev/null || true
sed -i \
    -e "s|host: localhost|host: ${GITLAB_HOST}|" \
    -e "s|port: 80\b|port: ${GITLAB_PORT}|" \
    -e "s|https: false|https: ${GITLAB_HTTPS}|" \
    -e "s|# ssh_port: 22|ssh_port: ${GITLAB_SSH_PORT}|" \
    -e "s|# relative_url_root: /gitlab|relative_url_root: ${GITLAB_RELATIVE_URL_ROOT}|" \
    config/gitlab.yml
chown git:git config/gitlab.yml

# --- secrets.yml ---
cat > "${GITLAB_DIR}/config/secrets.yml" <<SECRETS_EOF
production:
  db_key_base: "${GITLAB_SECRETS_DB_KEY_BASE}"
  secret_key_base: "${GITLAB_SECRETS_SECRET_KEY_BASE}"
  otp_key_base: "${GITLAB_SECRETS_OTP_KEY_BASE}"
SECRETS_EOF
chown git:git "${GITLAB_DIR}/config/secrets.yml"
chmod 0600 "${GITLAB_DIR}/config/secrets.yml"

# --- puma.rb ---
if [[ -f "${GITLAB_DIR}/config/puma.rb.example" ]]; then
    cp "${GITLAB_DIR}/config/puma.rb.example" "${GITLAB_DIR}/config/puma.rb"
fi
sed -i \
    -e "s|workers .*|workers ${PUMA_WORKERS}|" \
    -e "s|min_threads.*|min_threads = ${PUMA_MIN_THREADS}|" \
    -e "s|max_threads.*|max_threads = ${PUMA_MAX_THREADS}|" \
    "${GITLAB_DIR}/config/puma.rb" 2>/dev/null || true
chown git:git "${GITLAB_DIR}/config/puma.rb"

# --- Nginx: replace FQDN ---
sed -i "s|YOUR_SERVER_FQDN|${GITLAB_HOST}|g" /etc/nginx/sites-available/gitlab 2>/dev/null || true

###############################################################################
# Ensure directories
###############################################################################
mkdir -p /home/git/data
chown git:git /home/git/data

su - git -c "cd ${GITLAB_DIR} && mkdir -p \
    tmp/pids tmp/sockets tmp/cache tmp/sessions \
    public/uploads \
    shared/artifacts shared/pages shared/lfs-objects shared/packages \
    shared/terraform_state shared/ci_secure_files shared/external-diffs"

# Ensure log directory
su - git -c "mkdir -p ${GITLAB_DIR}/log"

# Ensure supervisord log directory
mkdir -p /var/log/supervisord

# Ensure SSH host keys
ssh-keygen -A 2>/dev/null || true
mkdir -p /run/sshd

###############################################################################
# Database initialization or migration
###############################################################################
cd "${GITLAB_DIR}"

if [[ ! -f "${INIT_MARKER}" ]]; then
    echo "=== First-time setup: Initializing database ==="

    # Start Gitaly temporarily (required for DB seeding)
    echo "Starting Gitaly temporarily..."
    su - git -c "cd ${GITALY_DIR} && \
        PATH=/usr/local/go/bin:/usr/local/bin:\$PATH \
        ./_build/bin/gitaly ${GITALY_DIR}/config.toml &"
    sleep 5

    # Run database setup
    su - git -c "cd ${GITLAB_DIR} && \
        PATH=/usr/local/go/bin:/usr/local/bin:\$PATH \
        RAILS_ENV=production \
        GITLAB_ROOT_PASSWORD='${GITLAB_ROOT_PASSWORD}' \
        GITLAB_ROOT_EMAIL='${GITLAB_ROOT_EMAIL}' \
        force=yes \
        bundle exec rake gitlab:setup"

    # Stop temporary Gitaly
    pkill -f 'gitaly' || true
    sleep 2

    # Mark as initialized
    touch "${INIT_MARKER}"
    chown git:git "${INIT_MARKER}"
    echo "=== Database initialization complete ==="

else
    echo "=== Running database migrations ==="

    # Start Gitaly temporarily (may be required for some migrations)
    su - git -c "cd ${GITALY_DIR} && \
        PATH=/usr/local/go/bin:/usr/local/bin:\$PATH \
        ./_build/bin/gitaly ${GITALY_DIR}/config.toml &"
    sleep 5

    su - git -c "cd ${GITLAB_DIR} && \
        PATH=/usr/local/go/bin:/usr/local/bin:\$PATH \
        RAILS_ENV=production \
        bundle exec rake db:migrate"

    # Stop temporary Gitaly
    pkill -f 'gitaly' || true
    sleep 2

    echo "=== Migrations complete ==="
fi

###############################################################################
# Clear caches
###############################################################################
su - git -c "cd ${GITLAB_DIR} && \
    PATH=/usr/local/go/bin:/usr/local/bin:\$PATH \
    RAILS_ENV=production \
    bundle exec rake cache:clear" 2>/dev/null || true

###############################################################################
# Start supervisord (PID 1)
###############################################################################
echo "=== Starting supervisord ==="
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
