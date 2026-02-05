#!/usr/bin/env bash
#
# GitLab CE Source Installation Script for Debian 13 (Trixie)
# Based on the official GitLab source installation guide
#
# Usage: sudo bash install-gitlab.sh
#
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Configuration Variables — Adjust these to match your environment
###############################################################################
GITLAB_BRANCH="18-8-stable"
RUBY_VERSION="3.2.10"
GO_VERSION="1.25.7"
NODE_MAJOR=22

GITLAB_HOST="192.168.3.21"
GITLAB_PORT="8900"
GITLAB_HTTPS="false"
EXTERNAL_URL="http://${GITLAB_HOST}:${GITLAB_PORT}"

# PostgreSQL
DB_USER="git"
DB_NAME="gitlabhq_production"
DB_HOST="localhost"
DB_PORT="5432"
DB_PASSWORD=""   # empty = peer auth (recommended for local install)

# Redis
REDIS_SOCKET="/var/run/redis/redis-server.sock"

# Paths
GIT_HOME="/home/git"
GITLAB_DIR="${GIT_HOME}/gitlab"

# Root password for initial setup (change this!)
GITLAB_ROOT_PASSWORD="ChangeMe123!"

###############################################################################
# Helper functions
###############################################################################
log() {
    echo ""
    echo "======================================================================"
    echo "  $1"
    echo "======================================================================"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (or with sudo)."
        exit 1
    fi
}

###############################################################################
check_root

log "Step 1/18: Installing system packages"
###############################################################################

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
    build-essential \
    cmake \
    pkg-config \
    zlib1g-dev \
    libgoogle-perftools-dev \
    libssl-dev \
    libreadline-dev \
    libncurses-dev \
    libffi-dev \
    libgdbm-dev \
    libre2-dev \
    libicu-dev \
    libkrb5-dev \
    libpq-dev \
    libsqlite3-dev \
    libyaml-dev \
    libxml2-dev \
    libxslt1-dev \
    libcurl4-openssl-dev \
    libpcre2-dev \
    curl \
    git \
    graphicsmagick \
    logrotate \
    openssh-server \
    rsync \
    sudo \
    wget \
    supervisor \
    nginx \
    postgresql \
    postgresql-client \
    redis-server \
    python3

###############################################################################
log "Step 2/18: Building Ruby ${RUBY_VERSION} from source"
###############################################################################

if ruby --version 2>/dev/null | grep -q "${RUBY_VERSION}"; then
    echo "Ruby ${RUBY_VERSION} is already installed, skipping."
else
    cd /tmp
    RUBY_TARBALL="ruby-${RUBY_VERSION}.tar.gz"
    if [[ ! -f "${RUBY_TARBALL}" ]]; then
        curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz" \
            -o "${RUBY_TARBALL}"
    fi
    tar xzf "${RUBY_TARBALL}"
    cd "ruby-${RUBY_VERSION}"
    ./configure --prefix=/usr/local --disable-install-rdoc --enable-shared
    make -j"$(nproc)"
    make install
    cd /
    rm -rf /tmp/ruby-${RUBY_VERSION} /tmp/${RUBY_TARBALL}
fi

gem install bundler --no-document

###############################################################################
log "Step 3/18: Installing Go ${GO_VERSION}"
###############################################################################

if go version 2>/dev/null | grep -q "${GO_VERSION}"; then
    echo "Go ${GO_VERSION} is already installed, skipping."
else
    ARCH=$(dpkg --print-architecture)
    cd /tmp
    GO_TARBALL="go${GO_VERSION}.linux-${ARCH}.tar.gz"
    curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "${GO_TARBALL}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${GO_TARBALL}"
    rm -f "${GO_TARBALL}"
fi

export PATH="/usr/local/go/bin:${PATH}"
echo 'export PATH="/usr/local/go/bin:${PATH}"' > /etc/profile.d/go.sh

###############################################################################
log "Step 4/18: Installing Node.js ${NODE_MAJOR}.x and Yarn"
###############################################################################

if node --version 2>/dev/null | grep -q "v${NODE_MAJOR}\."; then
    echo "Node.js ${NODE_MAJOR}.x is already installed, skipping."
else
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
    apt-get install -y -qq nodejs
fi

npm install --global yarn

###############################################################################
log "Step 5/18: Creating git user"
###############################################################################

if id git &>/dev/null; then
    echo "User 'git' already exists, skipping."
else
    adduser --disabled-login --gecos 'GitLab' git
fi

###############################################################################
log "Step 6/18: Setting up PostgreSQL"
###############################################################################

systemctl enable postgresql
systemctl start postgresql

# Create the database user and database
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${DB_USER} CREATEDB;"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

# Enable required extensions
sudo -u postgres psql -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
sudo -u postgres psql -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS btree_gist;"
sudo -u postgres psql -d "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS plpgsql;"

###############################################################################
log "Step 7/18: Setting up Redis"
###############################################################################

# Configure Redis to listen on a Unix socket
if ! grep -q "^unixsocket " /etc/redis/redis.conf; then
    cat >> /etc/redis/redis.conf <<EOF
unixsocket ${REDIS_SOCKET}
unixsocketperm 770
EOF
fi

# Add git user to redis group
usermod -aG redis git

systemctl enable redis-server
systemctl restart redis-server

###############################################################################
log "Step 8/18: Cloning GitLab CE source (${GITLAB_BRANCH})"
###############################################################################

if [[ -d "${GITLAB_DIR}" ]]; then
    echo "GitLab directory already exists, updating..."
    cd "${GITLAB_DIR}"
    sudo -u git -H git fetch origin
    sudo -u git -H git checkout "${GITLAB_BRANCH}"
    sudo -u git -H git pull origin "${GITLAB_BRANCH}"
else
    sudo -u git -H git clone https://gitlab.com/gitlab-org/gitlab-foss.git \
        -b "${GITLAB_BRANCH}" "${GITLAB_DIR}"
fi

cd "${GITLAB_DIR}"

###############################################################################
log "Step 9/18: Configuring GitLab"
###############################################################################

# --- gitlab.yml ---
sudo -u git -H cp config/gitlab.yml.example config/gitlab.yml
sudo -u git -H sed -i \
    -e "s|host: localhost|host: ${GITLAB_HOST}|" \
    -e "s|port: 80|port: ${GITLAB_PORT}|" \
    -e "s|https: false|https: ${GITLAB_HTTPS}|" \
    -e "s|# user: git|user: git|" \
    -e "s|/home/git/repositories|${GIT_HOME}/repositories|" \
    config/gitlab.yml

# --- secrets.yml ---
sudo -u git -H cp config/secrets.yml.example config/secrets.yml
sudo -u git -H chmod 0600 config/secrets.yml

# --- database.yml (template rewrite — only main + ci, no geo/embedding) ---
# IMPORTANT: The example file (database.yml.postgresql) contains unsupported
# sections (geo, embedding). We must write a clean file with only main + ci.
rm -f "${GITLAB_DIR}/config/database.yml"
cat > "${GITLAB_DIR}/config/database.yml" <<DBEOF
production:
  main:
    adapter: postgresql
    encoding: unicode
    database: ${DB_NAME}
    host: ${DB_HOST}
    port: ${DB_PORT}
    username: ${DB_USER}
    password: "${DB_PASSWORD}"
    prepared_statements: false
  ci:
    adapter: postgresql
    encoding: unicode
    database: ${DB_NAME}
    host: ${DB_HOST}
    port: ${DB_PORT}
    username: ${DB_USER}
    password: "${DB_PASSWORD}"
    prepared_statements: false
    database_tasks: false
DBEOF
chown git:git "${GITLAB_DIR}/config/database.yml"
chmod 0600 "${GITLAB_DIR}/config/database.yml"

# Verify database.yml was written correctly
if grep -q 'geo\|embedding' "${GITLAB_DIR}/config/database.yml"; then
    echo "ERROR: database.yml still contains unsupported sections!"
    exit 1
fi
echo "database.yml written successfully (main + ci only)."

# --- puma.rb ---
sudo -u git -H cp config/puma.rb.example config/puma.rb

# --- resque.yml (Redis) ---
sudo -u git -H cat > config/resque.yml <<EOF
production:
  url: unix:${REDIS_SOCKET}
EOF

# --- cable.yml (Action Cable / Redis) ---
sudo -u git -H cat > config/cable.yml <<EOF
production:
  adapter: redis
  url: unix:${REDIS_SOCKET}
EOF

# Ensure required directories
sudo -u git -H mkdir -p \
    tmp/pids/ tmp/sockets/ tmp/cache/ tmp/sessions/ \
    public/uploads/ \
    shared/artifacts/ shared/pages/ shared/lfs-objects/ shared/packages/ shared/terraform_state/ \
    shared/ci_secure_files/ shared/external-diffs/

sudo -u git -H chmod -R u+rwX tmp/ shared/ public/uploads/

# Log directory
sudo -u git -H mkdir -p log/
sudo -u git -H chmod -R u+rwX log/

# Gitaly config directory
sudo -u git -H mkdir -p "${GIT_HOME}/repositories"
sudo -u git -H chmod -R ug+rwX,o-rwx "${GIT_HOME}/repositories"

###############################################################################
log "Step 10/18: Installing Ruby gems (bundle install)"
###############################################################################

cd "${GITLAB_DIR}"
sudo -u git -H bundle config set --local deployment 'true'
sudo -u git -H bundle config set --local without 'development test kerberos'
sudo -u git -H bundle install

###############################################################################
log "Step 11/18: Installing GitLab Shell"
###############################################################################

cd "${GITLAB_DIR}"
sudo -u git -H bundle exec rake gitlab:shell:install RAILS_ENV=production

###############################################################################
log "Step 12/18: Installing GitLab Workhorse"
###############################################################################

cd "${GITLAB_DIR}"
sudo -u git -H bundle exec rake "gitlab:workhorse:install[${GIT_HOME}/gitlab-workhorse]" RAILS_ENV=production

###############################################################################
log "Step 13/18: Installing Gitaly"
###############################################################################

cd "${GITLAB_DIR}"
sudo -u git -H bundle exec rake "gitlab:gitaly:install[${GIT_HOME}/gitaly,${GIT_HOME}/repositories]" RAILS_ENV=production

# Configure Gitaly
cd "${GIT_HOME}/gitaly"
if [[ ! -f config.toml ]]; then
    sudo -u git -H cp config.toml.example config.toml
fi

sudo -u git -H sed -i \
    -e "s|/home/git/gitaly/run/gitaly.pid|/home/git/gitaly/gitaly.pid|" \
    config.toml

###############################################################################
log "Step 14/18: Initializing database"
###############################################################################

cd "${GITLAB_DIR}"

# Start Gitaly temporarily for DB setup
sudo -u git -H bash -c "cd ${GIT_HOME}/gitaly && ./run/gitaly &"
sleep 5

sudo -u git -H bash -c "cd ${GITLAB_DIR} && \
    echo 'yes' | bundle exec rake gitlab:setup RAILS_ENV=production \
    GITLAB_ROOT_PASSWORD='${GITLAB_ROOT_PASSWORD}' \
    GITLAB_ROOT_EMAIL='admin@local.host'"

# Stop temporary Gitaly
pkill -f 'gitaly' || true
sleep 2

###############################################################################
log "Step 15/18: Compiling assets"
###############################################################################

cd "${GITLAB_DIR}"
sudo -u git -H yarn install --production --pure-lockfile
sudo -u git -H bundle exec rake gitlab:assets:compile RAILS_ENV=production NODE_ENV=production

###############################################################################
log "Step 16/18: Setting up systemd services"
###############################################################################

# GitLab main service
cat > /etc/systemd/system/gitlab.target <<'EOF'
[Unit]
Description=GitLab
Wants=gitlab-puma.service gitlab-sidekiq.service gitlab-workhorse.service gitlab-gitaly.service
After=network.target postgresql.service redis-server.service

[Install]
WantedBy=multi-user.target
EOF

# Puma
cat > /etc/systemd/system/gitlab-puma.service <<EOF
[Unit]
Description=GitLab Puma Web Server
After=network.target postgresql.service redis-server.service gitlab-gitaly.service
Requires=gitlab-gitaly.service

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITLAB_DIR}
Environment=RAILS_ENV=production
Environment=NODE_ENV=production
Environment=PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/bundle exec puma -C ${GITLAB_DIR}/config/puma.rb
Restart=always
RestartSec=5

[Install]
WantedBy=gitlab.target
EOF

# Sidekiq
cat > /etc/systemd/system/gitlab-sidekiq.service <<EOF
[Unit]
Description=GitLab Sidekiq
After=network.target postgresql.service redis-server.service gitlab-gitaly.service
Requires=gitlab-gitaly.service

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITLAB_DIR}
Environment=RAILS_ENV=production
Environment=NODE_ENV=production
Environment=MALLOC_ARENA_MAX=2
Environment=PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/bundle exec sidekiq -C ${GITLAB_DIR}/config/sidekiq_queues.yml -e production
Restart=always
RestartSec=5

[Install]
WantedBy=gitlab.target
EOF

# Workhorse
cat > /etc/systemd/system/gitlab-workhorse.service <<EOF
[Unit]
Description=GitLab Workhorse
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITLAB_DIR}
Environment=PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${GIT_HOME}/gitlab-workhorse/gitlab-workhorse \\
    -listenUmask 0 \\
    -listenNetwork unix \\
    -listenAddr ${GITLAB_DIR}/tmp/sockets/gitlab-workhorse.socket \\
    -authBackend http://127.0.0.1:8080 \\
    -authSocket ${GITLAB_DIR}/tmp/sockets/gitlab.socket \\
    -documentRoot ${GITLAB_DIR}/public \\
    -secretPath ${GITLAB_DIR}/.gitlab_workhorse_secret
Restart=always
RestartSec=5

[Install]
WantedBy=gitlab.target
EOF

# Gitaly
cat > /etc/systemd/system/gitlab-gitaly.service <<EOF
[Unit]
Description=GitLab Gitaly
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GIT_HOME}/gitaly
Environment=HOME=${GIT_HOME}
Environment=PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${GIT_HOME}/gitaly/_build/bin/gitaly ${GIT_HOME}/gitaly/config.toml
Restart=always
RestartSec=5

[Install]
WantedBy=gitlab.target
EOF

systemctl daemon-reload
systemctl enable gitlab.target

###############################################################################
log "Step 17/18: Configuring Nginx"
###############################################################################

# Remove default site
rm -f /etc/nginx/sites-enabled/default

# Install GitLab Nginx config
cp "${GITLAB_DIR}/lib/support/nginx/gitlab" /etc/nginx/sites-available/gitlab

# Customize
sed -i \
    -e "s|YOUR_SERVER_FQDN|${GITLAB_HOST}|g" \
    -e "s|listen 80;|listen ${GITLAB_PORT};|" \
    -e "s|server unix:.*gitlab-workhorse.socket|server unix:${GITLAB_DIR}/tmp/sockets/gitlab-workhorse.socket|" \
    /etc/nginx/sites-available/gitlab

ln -sf /etc/nginx/sites-available/gitlab /etc/nginx/sites-enabled/gitlab

nginx -t
systemctl enable nginx
systemctl restart nginx

###############################################################################
log "Step 18/18: Running final checks"
###############################################################################

# Start all GitLab services
systemctl start gitlab.target

# Wait for services to initialize
sleep 10

cd "${GITLAB_DIR}"
sudo -u git -H bundle exec rake gitlab:env:info RAILS_ENV=production
sudo -u git -H bundle exec rake gitlab:check RAILS_ENV=production

log "Installation complete!"
echo ""
echo "  GitLab CE has been installed successfully."
echo ""
echo "  URL:      ${EXTERNAL_URL}"
echo "  Username: root"
echo "  Password: ${GITLAB_ROOT_PASSWORD}"
echo ""
echo "  To start GitLab:  sudo systemctl start gitlab.target"
echo "  To stop GitLab:   sudo systemctl stop gitlab.target"
echo ""
