#!/usr/bin/env bash
# install_offline_patroni_with_pg16.sh
# Purpose: verify offline repo, create local rpm repo, install PostgreSQL16 & Patroni offline
# Usage: sudo ./install_offline_patroni_with_pg16.sh /path/to/Final_repo
set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/install_offline_patroni_with_pg16.log"
exec > >(tee -a "$LOGFILE") 2>&1

# --- Configurable ---
FINAL_REPO="${1:-/home/jarvis0100/Public/postgres_install/Final_repo}"
RPMS_DIR="$FINAL_REPO/rpms"
WHEELS_DIR="$FINAL_REPO/pip_wheels"
LOCAL_REPO_FILE="/etc/yum.repos.d/local-offline.repo"
LOCAL_REPO_ID="local-offline"
# Packages to install from the local rpm repo
RPM_PKGS=( \
  postgresql16 postgresql16-server postgresql16-contrib postgresql16-libs \
  haproxy keepalived \
  python3-pip python3-setuptools python3-psycopg2 \
  createrepo_c dnf-plugins-core )
# Additional rpm-only fallback packages (if naming differs)
FALLBACK_RPMS=(haproxy keepalived python3-pip python3-setuptools python3-psycopg2 createrepo_c dnf-plugins-core)

# Python wheels / packages to install offline (order matters for some packages)
PY_WHEELS=(click py_consul psutil PyYAML python_dateutil urllib3 requests six certifi charset_normalizer idna prettytable wcwidth ydiff)
PATRONI_VERSION="4.0.7"

timestamp() { date "+%F %T"; }

echo "=== OFFLINE PATRONI + PostgreSQL16 INSTALLER ==="
echo "$(timestamp) Using Final_repo: $FINAL_REPO"
echo "$(timestamp) Logfile: $LOGFILE"

# ----- Basic validations -----
echo
echo "1) Validating Final_repo layout..."
if [ ! -d "$FINAL_REPO" ]; then
  echo "ERROR: Final_repo not found at $FINAL_REPO"
  exit 1
fi
if [ ! -d "$RPMS_DIR" ] || [ -z "$(ls -A "$RPMS_DIR" 2>/dev/null || true)" ]; then
  echo "ERROR: RPM directory missing or empty: $RPMS_DIR"
  exit 1
fi
if [ ! -d "$WHEELS_DIR" ] || [ -z "$(ls -A "$WHEELS_DIR" 2>/dev/null || true)" ]; then
  echo "ERROR: pip_wheels directory missing or empty: $WHEELS_DIR"
  exit 1
fi
echo "OK - repo directories present."

# ----- Ensure repodata exists (if not, build it) -----
echo
echo "2) Ensure repository metadata (repodata) in $RPMS_DIR..."
if [ -f "$RPMS_DIR/repodata/repomd.xml" ]; then
  echo "✔ repomd.xml found."
else
  echo "repomd.xml not found — running createrepo_c to generate metadata..."
  if ! command -v createrepo_c >/dev/null 2>&1; then
    echo "createrepo_c not found on system. Attempting to install from local RPMs..."
    # Try quick local install of createrepo_c rpm file from RPMS_DIR
    CREATA=$(ls -1 "$RPMS_DIR"/createrepo_c*.rpm 2>/dev/null | head -n1 || true)
    if [ -n "$CREATA" ]; then
      echo "Installing $CREATA"
      rpm -Uvh --nosignature --nodigest "$CREATA"
    else
      echo "ERROR: createrepo_c rpm not in $RPMS_DIR; cannot generate repo metadata."
      exit 1
    fi
  fi
  createrepo_c --no-database "$RPMS_DIR"
  echo "Created repodata in $RPMS_DIR/repodata"
fi

# ----- Create local yum/dnf repo config -----
echo
echo "3) Registering local dnf repo config -> $LOCAL_REPO_FILE"
cat > "$LOCAL_REPO_FILE" <<EOF
[$LOCAL_REPO_ID]
name=Local offline repo (Final_repo)
baseurl=file://$RPMS_DIR
enabled=1
gpgcheck=0
EOF
chmod 644 "$LOCAL_REPO_FILE"
echo "Local repo file written."

# ----- Make cache and verify packages exist in repo -----
echo
echo "4) Refreshing dnf cache for local repo..."
# Make sure dnf doesn't try to hit network repos during makecache - we allow other repos but prefer to create local cache
dnf clean all || true
# Use repofrompath to avoid contacting network by enabling only local repo for the cache op.
dnf --disablerepo='*' --enablerepo="$LOCAL_REPO_ID" makecache || true

echo
echo "5) Verifying required RPMs exist in the local repo..."
MISSING_PKGS=()
for pkg in "${RPM_PKGS[@]}"; do
  # repoquery works even when local repo is enabled
  if dnf --disablerepo='*' --enablerepo="$LOCAL_REPO_ID" repoquery --quiet --whatprovides "$pkg" > /dev/null 2>&1; then
    echo "✔ $pkg available in local repo"
  else
    echo "⚠ $pkg NOT found in local repo"
    MISSING_PKGS+=("$pkg")
  fi
done

if [ "${#MISSING_PKGS[@]}" -ne 0 ]; then
  echo
  echo "WARNING: Some requested RPMs are not present in the local repo."
  echo "Missing: ${MISSING_PKGS[*]}"
  echo "Attempting to continue installing available fallback packages (non-Postgres required packages)."
fi

# ----- Install RPM packages from the local repo -----
echo
echo "6) Installing RPM packages from local repo (offline)..."
# Build install list: include only packages available
AVAILABLE_PKGS=()
for pkg in "${RPM_PKGS[@]}"; do
  if dnf --disablerepo='*' --enablerepo="$LOCAL_REPO_ID" repoquery --quiet --whatprovides "$pkg" > /dev/null 2>&1; then
    AVAILABLE_PKGS+=("$pkg")
  fi
done

if [ "${#AVAILABLE_PKGS[@]}" -eq 0 ]; then
  echo "ERROR: No requested RPMs are available in the local repo. Aborting."
  exit 1
fi

echo "Installing: ${AVAILABLE_PKGS[*]}"
# Use --allowerasing to handle minor conflicts, but still offline
dnf -y --disablerepo='*' --enablerepo="$LOCAL_REPO_ID" install --allowerasing "${AVAILABLE_PKGS[@]}"

echo
echo "7) Installing additional fallback RPMs individually if needed..."
# If some packages still not installed but an rpm file exists in RPMS_DIR, try to install by filename
for fallback in "${FALLBACK_RPMS[@]}"; do
  if ! rpm -q --quiet "$fallback" 2>/dev/null; then
    # try to find an rpm file in rpms directory matching name
    found=$(ls -1 "$RPMS_DIR"/"$fallback"-*.rpm 2>/dev/null | head -n1 || true)
    if [ -n "$found" ]; then
      echo "Installing local RPM file: $found"
      rpm -Uvh --nosignature --nodigest "$found" || echo "WARN: rpm install of $found returned non-zero."
    fi
  fi
done

# ----- PostgreSQL initialization -----
echo
echo "8) PostgreSQL16 init and service enable (if installed)..."
if rpm -q --quiet postgresql16; then
  echo "PostgreSQL16 package is installed."
  # prefer the packaged helper script if present
  if [ -x /usr/pgsql-16/bin/postgresql-16-setup ]; then
    echo "Running /usr/pgsql-16/bin/postgresql-16-setup initdb"
    /usr/pgsql-16/bin/postgresql-16-setup initdb
  elif command -v postgresql-16-setup >/dev/null 2>&1; then
    echo "Running postgresql-16-setup initdb"
    postgresql-16-setup initdb
  else
    echo "No postgres setup helper found. Skipping automated initdb. You will need to run initdb manually:"
    echo "  /usr/pgsql-16/bin/postgresql-16-setup initdb  OR  /usr/pgsql-16/bin/initdb -D /var/lib/pgsql/16/data"
  fi

  # Try enabling service
  if systemctl enable --now postgresql-16 2>/dev/null; then
    echo "Enabled and started postgresql-16 service."
  elif systemctl enable --now postgresql-16.service 2>/dev/null; then
    echo "Enabled and started postgresql-16.service."
  else
    echo "Could not enable/start postgresql-16 via systemctl automatically — please enable/start manually."
  fi
else
  echo "PostgreSQL16 not installed. Skipping init/start."
fi

# ----- Python wheels & Patroni installation -----
echo
echo "9) Installing Python wheels (offline) into system Python"
# Ensure pip exists
if ! command -v pip3 >/dev/null 2>&1; then
  echo "ERROR: pip3 not found after RPM installation. Aborting wheel install."
  exit 1
fi

# First install dependencies available in WHEELS_DIR
DEPS_TO_INSTALL=()
for w in "${PY_WHEELS[@]}"; do
  # try to install by package name (pip will use --find-links to locate the file)
  # but first check if a matching wheel or tar.gz exists in WHEELS_DIR
  if ls "$WHEELS_DIR"/"$w"* 2>/dev/null | grep -q .; then
    DEPS_TO_INSTALL+=("$w")
  else
    echo "Note: wheel/source for $w not found in $WHEELS_DIR - pip may fail or skip."
  fi
done

if [ "${#DEPS_TO_INSTALL[@]}" -gt 0 ]; then
  echo "Installing dependency wheels: ${DEPS_TO_INSTALL[*]}"
  pip3 install --no-index --find-links "$WHEELS_DIR" "${DEPS_TO_INSTALL[@]}"
else
  echo "No dependency wheels found to install; continuing."
fi

# Finally install ydiff + patroni (install patroni --no-deps to avoid pip fetching from network)
echo "Installing ydiff (if wheel available)"
if ls "$WHEELS_DIR"/ydiff* 2>/dev/null | grep -q .; then
  pip3 install --no-index --find-links "$WHEELS_DIR" ydiff
fi

echo "Installing Patroni ${PATRONI_VERSION} (offline, --no-deps to prevent network access)"
pip3 install --no-index --find-links "$WHEELS_DIR" "patroni==${PATRONI_VERSION}" --no-deps || {
  echo "Patroni offline install failed; attempting install via wheel file..."
  # Try direct wheel file if present
  patwheel=$(ls "$WHEELS_DIR"/patroni-*.whl 2>/dev/null | head -n1 || true)
  if [ -n "$patwheel" ]; then
    pip3 install --no-index "$patwheel"
  else
    echo "No patroni wheel found in $WHEELS_DIR; aborting."
    exit 1
  fi
}

echo
echo "10) Create a sample Patroni systemd unit & example config (user should adjust)"
SYSTEMD_DIR="/etc/systemd/system"
PAT_UNIT="$SYSTEMD_DIR/patroni.service"
if [ ! -f "$PAT_UNIT" ]; then
  cat > "$PAT_UNIT" <<'UNIT'
[Unit]
Description=Patroni cluster member
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  echo "Wrote sample systemd unit to $PAT_UNIT (edit ExecStart and config path as needed)."
  systemctl daemon-reload || true
else
  echo "Patroni systemd unit already exists at $PAT_UNIT - not overwriting."
fi

# Create sample /etc/patroni (if not present)
if [ ! -d /etc/patroni ]; then
  mkdir -p /etc/patroni
  cat > /etc/patroni/patroni.yml <<'YML'
scope: mycluster
namespace: /service/
name: node1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 127.0.0.1:8008

etcd:
  host: 127.0.0.1:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
  initdb:
    - encoding: UTF8

postgresql:
  listen: 0.0.0.0:5432
  data_dir: /var/lib/pgsql/16/data
  bin_dir: /usr/pgsql-16/bin
  pgpass: /tmp/pgpass0
YML
  chown -R postgres:postgres /etc/patroni
  echo "Wrote sample /etc/patroni/patroni.yml (you must edit it for your cluster topology)."
else
  echo "/etc/patroni already exists - not overwriting."
fi

# ----- Final verification -----
echo
echo "11) Final verification: packages and python modules"
echo "--- RPMs ---"
for p in postgresql16 haproxy keepalived python3-pip python3-psycopg2; do
  if rpm -q --quiet "$p"; then
    echo "OK: $p installed"
  else
    echo "MISSING: $p"
  fi
done

echo "--- Python (pip) ---"
if python3 -c "import pkgutil,sys; exit(0 if pkgutil.find_loader('patroni') else 1)"; then
  echo "OK: patroni importable"
else
  echo "WARN: patroni not importable from system python"
fi

echo
echo "=== DONE ==="
echo "Local repo used : $RPMS_DIR"
echo "Local wheels dir: $WHEELS_DIR"
echo
echo "NEXT STEPS / NOTES:"
echo " - Edit /etc/patroni/patroni.yml to include your actual etcd/consul endpoints, cluster names, and network addresses."
echo " - Configure HAProxy and keepalived config files under /etc/haproxy and /etc/keepalived as needed."
echo " - Start and enable patroni after config is finalized:"
echo "     sudo systemctl enable --now patroni"
echo " - If PostgreSQL initdb was skipped, run the packaged helper on the target:"
echo "     sudo /usr/pgsql-16/bin/postgresql-16-setup initdb"
echo
echo "Logfile: $LOGFILE"
exit 0

