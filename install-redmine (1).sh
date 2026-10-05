#!/usr/bin/env bash
#===============================================================================
# Redmine installer for AlmaLinux 9.x / 10.x  (also Rocky / RHEL 9+)
#
# Stack : Redmine 7.0.x + Ruby 3.3 (AppStream) + PostgreSQL 16 (AppStream)
#         Puma (systemd, 127.0.0.1:3000) behind nginx on port 80
# Access: http://<server-ip>/     (no domain, no TLS)
# Docker: not used
#
# Usage : sudo bash install-redmine.sh
# Re-run: safe (idempotent) - reuses existing DB password, DB and app tree
#
# Optional overrides (env):
#   REDMINE_VERSION=7.0.2  REDMINE_SHA256=<sha256 of tar.gz>
#   APP_DIR=/opt/redmine   APP_PORT=3000   HTTP_PORT=80
#   REDMINE_LANG=en        PUMA_WORKERS=2
#===============================================================================
set -Eeuo pipefail

REDMINE_VERSION="${REDMINE_VERSION:-7.0.2}"
DEFAULT_VERSION="7.0.2"
DEFAULT_SHA256="d45e6d4c373cc3c8d33f1f4d4a2ffae1e1adb18703160707467493de7b4be591"
REDMINE_SHA256="${REDMINE_SHA256:-}"
APP_DIR="${APP_DIR:-/opt/redmine}"
APP_USER="redmine"
APP_PORT="${APP_PORT:-3000}"
HTTP_PORT="${HTTP_PORT:-80}"
REDMINE_LANG="${REDMINE_LANG:-en}"
PUMA_WORKERS="${PUMA_WORKERS:-2}"
DB_NAME="redmine"
DB_USER="redmine"
CRED_FILE="/root/redmine-credentials.txt"
LOG_FILE="/var/log/redmine-install.log"

#--- helpers -------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "[FAIL] Run as root (sudo bash $0)"; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1
c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_r=$'\e[1;31m'; c_0=$'\e[0m'
step() { echo; echo "${c_g}==> $*${c_0}"; }
warn() { echo "${c_y}[WARN] $*${c_0}"; }
die()  { echo "${c_r}[FAIL] $*${c_0}"; exit 1; }
trap 'die "Line $LINENO: \"$BASH_COMMAND\" failed. Full log: $LOG_FILE"' ERR

as_pg() { ( cd /tmp && runuser -u postgres -- "$@" ); }
as_app() {
  runuser -u "$APP_USER" -- env HOME="$APP_DIR" RAILS_ENV=production \
    REDMINE_LANG="$REDMINE_LANG" PATH=/usr/local/bin:/usr/bin:/bin \
    bash -c "cd '$APP_DIR' && $1"
}

#--- 0. preflight --------------------------------------------------------------
step "Preflight"
. /etc/os-release
MAJOR="${VERSION_ID%%.*}"
case "$ID" in
  almalinux|rocky|rhel|centos|ol) ;;
  *) die "Unsupported distro: $ID (need AlmaLinux/EL 9+)";;
esac
(( MAJOR >= 9 )) || die "Need EL 9 or newer, found $VERSION_ID"
echo "OS: $PRETTY_NAME | Redmine: $REDMINE_VERSION | Dir: $APP_DIR"

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-127.0.0.1}"

#--- 1. repos + packages -------------------------------------------------------
step "Repositories (CRB, EPEL) and module streams"
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb || warn "Could not enable CRB"
dnf -y install epel-release || warn "EPEL not installed (ImageMagick may be missing)"

PG_DATA="/var/lib/pgsql/data"
if (( MAJOR == 9 )); then
  dnf -y module reset ruby
  dnf -y module enable ruby:3.3
  if [[ ! -f "$PG_DATA/PG_VERSION" ]]; then
    dnf -y module reset postgresql
    dnf -y module enable postgresql:16
  else
    warn "Existing PostgreSQL cluster found (v$(cat "$PG_DATA/PG_VERSION")) - reusing it"
  fi
fi

step "Installing packages"
dnf -y install \
  ruby ruby-devel rubygem-bundler rubygems \
  gcc gcc-c++ make patch redhat-rpm-config cmake pkgconf-pkg-config \
  libpq-devel libyaml-devel zlib-devel openssl-devel libffi-devel \
  libxml2-devel libxslt-devel readline-devel \
  postgresql-server postgresql \
  nginx git subversion tar curl openssl ghostscript \
  policycoreutils-python-utils logrotate
dnf -y install ImageMagick || warn "ImageMagick unavailable - thumbnails/Gantt PNG export disabled"

ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2") ? 0 : 1)' \
  || die "Ruby $(ruby -e 'print RUBY_VERSION') is too old for Redmine $REDMINE_VERSION (need >= 3.2)"
echo "Ruby: $(ruby -v)"
BUNDLE_BIN="$(command -v bundle)" || die "bundler not found"

#--- 2. PostgreSQL -------------------------------------------------------------
step "PostgreSQL"
if [[ ! -f "$PG_DATA/PG_VERSION" ]]; then
  postgresql-setup --initdb
fi
systemctl enable --now postgresql

if [[ -f "$CRED_FILE" ]] && grep -q '^DB_PASS=' "$CRED_FILE"; then
  DB_PASS="$(awk -F= '/^DB_PASS=/{print $2}' "$CRED_FILE")"
  echo "Reusing DB password from $CRED_FILE"
else
  DB_PASS="$(openssl rand -hex 16)"
fi

as_pg psql -v ON_ERROR_STOP=1 -q <<SQL
SET password_encryption = 'scram-sha-256';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN NOINHERIT;
  END IF;
END
\$\$;
ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
SQL

if ! as_pg psql -Atc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  as_pg createdb -O "$DB_USER" -E UTF8 -T template0 "$DB_NAME"
fi

HBA_FILE="$(as_pg psql -Atc 'SHOW hba_file')"
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    127.0.0.1/32    scram-sha-256"
if ! grep -qE "^host[[:space:]]+${DB_NAME}[[:space:]]+${DB_USER}[[:space:]]+127\.0\.0\.1/32" "$HBA_FILE"; then
  cp -a "$HBA_FILE" "${HBA_FILE}.bak.$(date +%s)"
  sed -i "1i ${HBA_LINE}" "$HBA_FILE"      # first match wins -> must be on top
fi
systemctl reload postgresql

PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -Atc 'SELECT 1' >/dev/null \
  || die "DB login test failed (check $HBA_FILE)"
echo "PostgreSQL $(as_pg psql -Atc 'SHOW server_version') - DB login OK"

umask 077
cat > "$CRED_FILE" <<EOF
# Redmine install - $(date -Is)
URL=http://${SERVER_IP}$([[ "$HTTP_PORT" == 80 ]] || echo ":$HTTP_PORT")/
ADMIN_LOGIN=admin
ADMIN_PASSWORD=admin   (forced change on first login)
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
APP_DIR=${APP_DIR}
EOF
umask 022

#--- 3. Redmine source ---------------------------------------------------------
step "Redmine $REDMINE_VERSION source"
id "$APP_USER" &>/dev/null || useradd -r -m -d "$APP_DIR" -s /sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR"

if [[ ! -f "$APP_DIR/Rakefile" ]]; then
  TARBALL="/tmp/redmine-${REDMINE_VERSION}.tar.gz"
  curl -fL --retry 3 -o "$TARBALL" "https://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz"
  [[ -z "$REDMINE_SHA256" && "$REDMINE_VERSION" == "$DEFAULT_VERSION" ]] && REDMINE_SHA256="$DEFAULT_SHA256"
  if [[ -n "$REDMINE_SHA256" ]]; then
    echo "${REDMINE_SHA256}  ${TARBALL}" | sha256sum -c - || die "Checksum mismatch on $TARBALL"
  else
    warn "No REDMINE_SHA256 given for $REDMINE_VERSION - skipping checksum verification"
  fi
  tar -xzf "$TARBALL" -C "$APP_DIR" --strip-components=1
  rm -f "$TARBALL"
else
  echo "Existing Redmine tree in $APP_DIR - keeping it"
fi

#--- 4. configuration ----------------------------------------------------------
step "Configuration files"
cat > "$APP_DIR/config/database.yml" <<EOF
production:
  adapter: postgresql
  database: ${DB_NAME}
  host: 127.0.0.1
  port: 5432
  username: ${DB_USER}
  password: "${DB_PASS}"
  encoding: utf8
  pool: 20
EOF

[[ -f "$APP_DIR/config/configuration.yml" ]] || \
  cp "$APP_DIR/config/configuration.yml.example" "$APP_DIR/config/configuration.yml"

grep -qs "puma" "$APP_DIR/Gemfile.local" || echo "gem 'puma'" >> "$APP_DIR/Gemfile.local"

cat > "$APP_DIR/config/puma.production.rb" <<EOF
environment 'production'
directory   '${APP_DIR}'
bind        'tcp://127.0.0.1:${APP_PORT}'
threads     4, 16
workers     ${PUMA_WORKERS}
preload_app!
pidfile     '${APP_DIR}/tmp/pids/puma.pid'
EOF

mkdir -p "$APP_DIR"/{files,log,tmp/pdf,tmp/pids,public/assets,plugins}
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 755 "$APP_DIR"
chmod 640 "$APP_DIR/config/database.yml"

#--- 5. gems -------------------------------------------------------------------
step "Bundle install (takes a few minutes)"
as_app "bundle config set --local without 'development test'"
as_app "bundle config set --local path vendor/bundle"
if ! as_app "bundle install --jobs $(nproc)"; then
  warn "bundle install failed - adding Rust/clang toolchain and retrying"
  dnf -y install rust cargo clang
  as_app "bundle install --jobs $(nproc)"
fi

#--- 6. secret, schema, default data, assets -----------------------------------
step "Secret token, DB migration, default data, assets"
[[ -f "$APP_DIR/config/initializers/secret_token.rb" ]] || as_app "bundle exec rake generate_secret_token"
as_app "bundle exec rake db:migrate"
if [[ ! -f "$APP_DIR/.default_data_loaded" ]]; then
  as_app "bundle exec rake redmine:load_default_data"
  as_app "touch .default_data_loaded"
fi
as_app "bundle exec rake redmine:plugins:migrate" || true
as_app "bundle exec rake assets:precompile"
find "$APP_DIR"/{files,log,tmp,public/assets} -type f -exec chmod -x {} +

#--- 7. systemd ----------------------------------------------------------------
step "systemd service"
cat > /etc/systemd/system/redmine.service <<EOF
[Unit]
Description=Redmine (Puma)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=RAILS_ENV=production
Environment=HOME=${APP_DIR}
ExecStart=${BUNDLE_BIN} exec puma -C ${APP_DIR}/config/puma.production.rb
Restart=always
RestartSec=5
TimeoutStartSec=180
SyslogIdentifier=redmine
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable redmine
systemctl restart redmine

#--- 8. nginx ------------------------------------------------------------------
step "nginx reverse proxy on port $HTTP_PORT"
if grep -qE 'listen[^;]*default_server' /etc/nginx/nginx.conf; then
  cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%s)"
  sed -i -E 's/(listen[^;]*)[[:space:]]+default_server/\1/' /etc/nginx/nginx.conf
fi
cat > /etc/nginx/conf.d/redmine.conf <<EOF
upstream redmine_puma {
    server 127.0.0.1:${APP_PORT} fail_timeout=0;
}

server {
    listen ${HTTP_PORT} default_server;
    server_name _;

    root ${APP_DIR}/public;
    client_max_body_size 100m;
    access_log /var/log/nginx/redmine_access.log;
    error_log  /var/log/nginx/redmine_error.log;

    location / {
        try_files \$uri @app;
    }

    location ^~ /assets/ {
        try_files \$uri @app;
        expires 30d;
        add_header Cache-Control "public";
    }

    location @app {
        proxy_pass http://redmine_puma;
        proxy_http_version 1.1;
        proxy_set_header Host              \$http_host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_send_timeout 300;
        proxy_redirect off;
    }
}
EOF

#--- 9. SELinux + firewall -----------------------------------------------------
step "SELinux and firewall"
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  setsebool -P httpd_can_network_connect 1
  semanage fcontext -a -t httpd_sys_content_t "${APP_DIR}/public(/.*)?" 2>/dev/null \
    || semanage fcontext -m -t httpd_sys_content_t "${APP_DIR}/public(/.*)?"
  restorecon -R "${APP_DIR}/public"
  if [[ "$HTTP_PORT" != 80 ]]; then
    semanage port -a -t http_port_t -p tcp "$HTTP_PORT" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "$HTTP_PORT" || true
  fi
fi

if systemctl is-active --quiet firewalld; then
  if [[ "$HTTP_PORT" == 80 ]]; then
    firewall-cmd --permanent --add-service=http
  else
    firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp"
  fi
  firewall-cmd --reload
else
  warn "firewalld not active - skipping firewall rule"
fi

nginx -t
systemctl enable nginx
systemctl restart nginx

#--- 10. logrotate -------------------------------------------------------------
cat > /etc/logrotate.d/redmine <<EOF
${APP_DIR}/log/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su ${APP_USER} ${APP_USER}
}
EOF

#--- 11. health check ----------------------------------------------------------
step "Health check"
CODE=000
for _ in $(seq 1 60); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/" || true)"
  [[ "$CODE" == 200 || "$CODE" == 302 ]] && break
  sleep 3
done
if [[ "$CODE" != 200 && "$CODE" != 302 ]]; then
  journalctl -u redmine -n 40 --no-pager || true
  die "Redmine not answering (HTTP $CODE). Check: journalctl -u redmine ; $APP_DIR/log/production.log"
fi

trap - ERR
URL="http://${SERVER_IP}$([[ "$HTTP_PORT" == 80 ]] || echo ":$HTTP_PORT")/"
cat <<EOF

${c_g}===============================================================
 Redmine ${REDMINE_VERSION} is up  (HTTP ${CODE})
===============================================================${c_0}
 URL          : ${URL}
 Login        : admin / admin   (password change forced at first login)
 App dir      : ${APP_DIR}
 Attachments  : ${APP_DIR}/files
 App log      : ${APP_DIR}/log/production.log
 Credentials  : ${CRED_FILE}
 Install log  : ${LOG_FILE}

 Service      : systemctl {status|restart} redmine
 Logs         : journalctl -u redmine -f
 Backup       : pg_dump -h 127.0.0.1 -U ${DB_USER} ${DB_NAME} | gzip > redmine.sql.gz
                tar czf redmine-files.tgz -C ${APP_DIR} files
 SMTP         : edit ${APP_DIR}/config/configuration.yml, then restart redmine
EOF
