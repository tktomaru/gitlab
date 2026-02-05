# =============================================================================
# GitLab CE Source Build — Dockerfile
# Base: Debian 13 (Trixie)
# =============================================================================
FROM debian:trixie

LABEL maintainer="GitLab CE Source Build"
LABEL description="GitLab CE built from source on Debian Trixie"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Versions
ENV RUBY_VERSION=3.2.6 \
    GO_VERSION=1.22.5 \
    NODE_MAJOR=20 \
    GITLAB_BRANCH=18-8-stable

# Paths
ENV GIT_HOME=/home/git \
    GITLAB_DIR=/home/git/gitlab \
    GITALY_DIR=/home/git/gitaly \
    PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"

# =============================================================================
# Step 1: System packages
# =============================================================================
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
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
    python3 \
    netcat-openbsd \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Step 2: Ruby from source
# =============================================================================
RUN cd /tmp \
    && curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz" \
        -o ruby.tar.gz \
    && tar xzf ruby.tar.gz \
    && cd ruby-${RUBY_VERSION} \
    && ./configure --prefix=/usr/local --disable-install-rdoc --enable-shared \
    && make -j"$(nproc)" \
    && make install \
    && cd / && rm -rf /tmp/ruby* \
    && gem install bundler --no-document

# =============================================================================
# Step 3: Go binary
# =============================================================================
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
        -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# =============================================================================
# Step 4: Node.js + Yarn
# =============================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y -qq nodejs \
    && npm install --global yarn \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Step 5: Create git user
# =============================================================================
RUN adduser --disabled-login --gecos 'GitLab' git

# =============================================================================
# Step 6: Clone GitLab CE source (shallow clone)
# =============================================================================
RUN sudo -u git -H git clone https://gitlab.com/gitlab-org/gitlab-foss.git \
        --depth 1 -b ${GITLAB_BRANCH} ${GITLAB_DIR}

# =============================================================================
# Step 7: Configure GitLab
# =============================================================================
WORKDIR ${GITLAB_DIR}

# Copy example configs
RUN sudo -u git -H cp config/gitlab.yml.example config/gitlab.yml \
    && sudo -u git -H cp config/secrets.yml.example config/secrets.yml \
    && sudo -u git -H chmod 0600 config/secrets.yml \
    && sudo -u git -H cp config/puma.rb.example config/puma.rb \
    && sudo -u git -H cp config/database.yml.postgresql config/database.yml \
    && sudo -u git -H chmod 0600 config/database.yml

# Create required directories
RUN sudo -u git -H mkdir -p \
        tmp/pids tmp/sockets tmp/cache tmp/sessions \
        public/uploads \
        shared/artifacts shared/pages shared/lfs-objects shared/packages \
        shared/terraform_state shared/ci_secure_files shared/external-diffs \
        log \
        ${GIT_HOME}/repositories \
    && sudo -u git -H chmod -R u+rwX tmp/ shared/ public/uploads/ log/ \
    && sudo -u git -H chmod -R ug+rwX,o-rwx ${GIT_HOME}/repositories

# =============================================================================
# Step 8: Bundle install
# =============================================================================
RUN sudo -u git -H bundle config set --local deployment 'true' \
    && sudo -u git -H bundle config set --local without 'development test kerberos' \
    && sudo -u git -H bundle install

# =============================================================================
# Step 9: Install GitLab Shell
# =============================================================================
RUN sudo -u git -H bundle exec rake gitlab:shell:install RAILS_ENV=production

# =============================================================================
# Step 10: Install GitLab Workhorse
# =============================================================================
RUN sudo -u git -H bundle exec rake \
        "gitlab:workhorse:install[${GIT_HOME}/gitlab-workhorse]" RAILS_ENV=production

# =============================================================================
# Step 11: Install Gitaly
# =============================================================================
RUN sudo -u git -H bundle exec rake \
        "gitlab:gitaly:install[${GITALY_DIR},${GIT_HOME}/repositories]" RAILS_ENV=production

# Configure Gitaly — use example config if available
RUN cd ${GITALY_DIR} \
    && if [ -f config.toml.example ]; then \
        sudo -u git -H cp config.toml.example config.toml; \
    fi

# =============================================================================
# Step 12: Compile assets
# =============================================================================
RUN sudo -u git -H yarn install --production --pure-lockfile \
    && sudo -u git -H bundle exec rake gitlab:assets:compile \
        RAILS_ENV=production NODE_ENV=production \
    && sudo -u git -H yarn cache clean

# =============================================================================
# Step 13: Nginx configuration
# =============================================================================
RUN rm -f /etc/nginx/sites-enabled/default \
    && cp ${GITLAB_DIR}/lib/support/nginx/gitlab /etc/nginx/sites-available/gitlab \
    && ln -sf /etc/nginx/sites-available/gitlab /etc/nginx/sites-enabled/gitlab

# =============================================================================
# Step 14: SSH configuration
# =============================================================================
RUN mkdir -p /run/sshd \
    && ssh-keygen -A

# =============================================================================
# Step 15: Supervisord and entrypoint
# =============================================================================
RUN mkdir -p /var/log/supervisord

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY nginx.conf /etc/nginx/sites-available/gitlab

RUN chmod +x /docker-entrypoint.sh

# =============================================================================
# Step 16: Data volume and permissions
# =============================================================================
RUN mkdir -p /home/git/data \
    && chown -R git:git /home/git/data

VOLUME ["${GIT_HOME}/repositories", "${GIT_HOME}/data", \
        "${GITLAB_DIR}/shared", "${GITLAB_DIR}/public/uploads", \
        "${GITLAB_DIR}/log"]

EXPOSE 80 443 22

ENTRYPOINT ["/docker-entrypoint.sh"]
