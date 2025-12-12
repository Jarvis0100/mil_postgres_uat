#!/usr/bin/env bash
set -euo pipefail

# install_from_usb_offline.sh
# Usage:
#   sudo ./install_from_usb_offline.sh [USB_PATH]
# If USB_PATH not provided, script will search common mount points for "Final_repo".

LOG=/var/log/install_from_usb_offline.log
exec > >(tee -a "$LOG") 2>&1

echo "=== OFFLINE INSTALLER FROM USB ==="
echo "Log: $LOG"
echo

# -------------------------
# Configurable variables
# -------------------------
TARGET="/opt/offline_repo"            # where repo will be copied to on the target system
REPO_SUBDIR="Final_repo"             # expected folder name on USB
RPM_SUBDIR="rpms"
WHEEL_SUBDIR="pip_wheels"
LOCAL_REPO_FILE="/etc/yum.repos.d/local-offline.repo"
PG_SERVICE="postgresql-16"
PATRONI_SERVICE="patroni"
PATRONI_WHEEL_NAME="patroni"         # exact patroni wheel name (version handled by pip)
PATRONI_VERSION="4.0.7"              # the version we intend to install
# -------------------------

# Helper: find Final_repo on common mount points
find_repo_on_mounts() {
    # argument optional hint: $1 path to check explicitly first
    local hint="$1"
    if [[ -n "$hint" && -d "$hint/$REPO_SUBDIR" ]]; then
        echo "$hint/$REPO_SUBDIR"
        return 0
    fi

    # common mount points to search (in order)
    local candidates=(
        "/run/media/$(logname)/*/$REPO_SUBDIR"   # many distros mount here
        "/media/$(logname)/*/$REPO_SUBDIR"
        "/media/*/$REPO_SUBDIR"
        "/mnt/$REPO_SUBDIR"
        "/mnt/*/$REPO_SUBDIR"
        "/run/media/*/$REPO_SUBDIR"
        "/home/$(logname)/$REPO_SUBDIR"
    )

    for p in "${candidates[@]}"; do
        # Use globbing to expand wildcards
        for f in $(compgen -G "$p" 2>/dev/null || true); do
            if [[ -d "$f" ]]; then
                echo "$f"
                return 0
            fi
        done
    done

    return 1
}

# Step 0: Accept optional arg
USB_HINT="${1:-}"
if [[ -n "$USB_HINT" ]]; then
    echo "[INFO] USB path provided: $USB_HINT"
fi

echo "[STEP 1] Locating '$REPO_SUBDIR' on USB / mounts..."
REPO_PATH="$(find_repo_on_mounts "$USB_HINT" || true)"

if [[ -z "$REPO_PATH" ]]; then
    echo "❌ ERROR: Could not find a directory named '$REPO_SUBDIR' on common mount points."
    echo "Please mount your USB and ensure it contains: $REPO_SUBDIR/"
    exit 1
fi

echo "✔ Found offline repo at: $REPO_PATH"

# Step 2: Validate layout on USB
if [[ ! -d "$REPO_PATH/$RPM_SUBDIR" ]]; then
    echo "❌ ERROR: RPM directory not found under $REPO_PATH/$RPM_SUBDIR"
    exit 1
fi
if [[ ! -d "$REPO_PATH/$WHEEL_SUBDIR" ]]; then
    echo "❌ ERROR: Wheel directory not found under $REPO_PATH/$WHEEL_SUBDIR"
    exit 1
fi

echo "[STEP 2] Copying repo to local path: $TARGET (this avoids depending on the USB mount later)..."
mkdir -p "$TARGET"
rsync -a --delete "$REPO_PATH/" "$TARGET/" || { echo "❌ rsync failed"; exit 1; }
echo "✔ Repo copied to $TARGET"

RPM_DIR="$TARGET/$RPM_SUBDIR"
WHEEL_DIR="$TARGET/$WHEEL_SUBDIR"

# Step 3: Ensure repomd exists or create metadata
if [[ ! -f "$RPM_DIR/repodata/repomd.xml" ]]; then
    echo "[STEP 3] No repodata found — creating repo metadata with createrepo_c..."
    if ! command -v createrepo_c >/dev/null 2>&1; then
        echo "Note: createrepo_c not installed on this host. We'll try to use the rpm packages from the local repo to install it."
    fi

    # Try to use local createrepo_c rpm if present
    local_createrepo_pkg=$(ls "$RPM_DIR" | grep -E 'createrepo_c-.*\.rpm' || true)
    if [[ -n "$local_createrepo_pkg" ]]; then
        echo "Installing createrepo_c from local RPM..."
        dnf --nogpgcheck --disablerepo='*' --enablerepo='*' localinstall -y "$RPM_DIR/$local_createrepo_pkg" || true
    fi

    # If createrepo_c now exists, run it
    if command -v createrepo_c >/dev/null 2>&1; then
        createrepo_c "$RPM_DIR"
        echo "✔ repodata created"
    else
        echo "⚠ WARNING: createrepo_c not available — cannot create repodata. If repodata is required, re-run with createrepo_c available."
    fi
else
    echo "✔ repodata exists in RPM directory"
fi

# Step 4: Register local repo file
echo "[STEP 4] Registering local dnf repo file at: $LOCAL_REPO_FILE"
cat > "$LOCAL_REPO_FILE" <<EOF
[local-offline]
name=Offline Repo (copied from USB)
baseurl=file://$RPM_DIR
enabled=1
gpgcheck=0
priority=1
EOF

# Clean and makecache for only local repo
echo "[STEP 5] Refreshing local repo metadata..."
dnf clean all || true
# we enable only this local repo to avoid network
dnf --disablerepo="*" --enablerepo="local-offline" makecache

# Step 6: Check required packages availability
echo "[STEP 6] Verifying required RPMs are present in local repo..."

missing=()

need_pkgs=( \
  postgresql16 \
  postgresql16-server \
  postgresql16-contrib \
  postgresql16-libs \
  haproxy \
  keepalived \
  python3-pip \
  python3-setuptools \
  python3-psycopg2 \
  createrepo_c \
  dnf-plugins-core )

for pkg in "${need_pkgs[@]}"; do
    if ! dnf --disablerepo="*" --enablerepo="local-offline" repoquery --quiet --whatprovides "$pkg" >/dev/null 2>&1; then
        missing+=("$pkg")
    else
        echo "  ✔ $pkg -> available"
    fi
done

if (( ${#missing[@]} > 0 )); then
    echo
    echo "❌ ERROR: The following packages are missing from your offline repo:"
    for m in "${missing[@]}"; do echo "   - $m"; done
    echo
    echo "Either copy these rpm(s) into $RPM_DIR on the USB and re-run, or disable optional components in your workflow."
    exit 2
fi

# Step 7: Install RPMs from local repo (offline)
echo "[STEP 7] Installing required RPMs (offline) from local repo..."
dnf --disablerepo="*" --enablerepo="local-offline" install -y "${need_pkgs[@]}" || {
    echo "❌ ERROR: dnf failed to install required RPMs from local repo. Check $LOG and the RPMs in $RPM_DIR"
    exit 3
}
echo "✔ Core RPMs installed"

# Step 8: Recreate repo metadata (safety)
if command -v createrepo_c >/dev/null 2>&1; then
    echo "[STEP 8] (safety) recreate repodata"
    createrepo_c --update "$RPM_DIR" || true
fi

# Step 9: Install python wheels (Patroni and deps) offline
echo "[STEP 9] Installing Python wheels offline from: $WHEEL_DIR"
if [[ ! -d "$WHEEL_DIR" ]]; then
    echo "❌ ERROR: Wheel dir $WHEEL_DIR missing"
    exit 1
fi

# Ensure pip exists
if ! command -v pip3 >/dev/null 2>&1; then
    echo "❌ ERROR: pip3 not found after RPM install. Ensure python3-pip RPM installed correctly."
    exit 1
fi

# Install patroni and dependencies from local wheel folder
pip3 install --no-index --find-links "$WHEEL_DIR" "patroni==$PATRONI_VERSION" || {
    echo "❌ ERROR: pip install failed. Ensure all required wheel files are present in $WHEEL_DIR."
    ls -1 "$WHEEL_DIR"
    exit 4
}

echo "✔ Patroni and Python deps installed from wheels"

# Step 10: Initialize PostgreSQL 16 database if needed
echo "[STEP 10] Initializing PostgreSQL 16 data dir (if not present)..."
if [[ ! -d /var/lib/pgsql/16/data || -z "$(ls -A /var/lib/pgsql/16/data 2>/dev/null || true)" ]]; then
    echo "-> Running postgresql-16-setup initdb"
    if /usr/pgsql-16/bin/postgresql-16-setup --help >/dev/null 2>&1; then
        /usr/pgsql-16/bin/postgresql-16-setup initdb
    else
        # some systems provide script under different path
        if command -v postgresql-16-setup >/dev/null 2>&1; then
            postgresql-16-setup initdb
        else
            echo "⚠ WARNING: Could not find postgresql-16-setup script. Data dir initialization will be skipped — initialize manually later."
        fi
    fi
else
    echo "✔ PostgreSQL data dir exists"
fi

# Enable and start PostgreSQL service
echo "[STEP 11] Enabling and starting PostgreSQL service..."
systemctl enable "$PG_SERVICE" || true
systemctl start "$PG_SERVICE" || {
    echo "⚠ WARNING: Starting $PG_SERVICE failed. Check journalctl -u $PG_SERVICE"
}

# Step 12: Create Patroni systemd service if not present
echo "[STEP 12] Creating minimal Patroni systemd unit + config (if missing)..."
if [[ ! -f /etc/systemd/system/patroni.service ]]; then
  cat > /etc/systemd/system/patroni.service <<'EOF'
[Unit]
Description=Patroni PostgreSQL HA Manager
After=network.target

[Service]
Type=simple
User=postgres
Environment=PATRONI_CONFIG=/etc/patroni.yml
ExecStart=/usr/local/bin/patroni /etc/patroni.yml
Restart=always
LimitNOFILE=10240

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  echo "✔ patroni.service created"
else
  echo "✔ patroni.service already exists"
fi

# Create a minimal default patroni.yml if missing (you will likely edit this)
if [[ ! -f /etc/patroni.yml ]]; then
  cat > /etc/patroni.yml <<EOF
scope: pg16
name: node1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 127.0.0.1:8008

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 127.0.0.1:5432
  data_dir: /var/lib/pgsql/16/data
  bin_dir: /usr/pgsql-16/bin/
  authentication:
    superuser:
      username: postgres
      password: postgres
    replication:
      username: replicator
      password: replicator123
EOF
  echo "✔ /etc/patroni.yml created (edit as needed)"
else
  echo "✔ /etc/patroni.yml already exists"
fi

# Step 13: Start Patroni service
echo "[STEP 13] Enabling and starting Patroni service..."
systemctl enable patroni || true
systemctl start patroni || {
    echo "⚠ WARNING: Starting patroni failed. Check journalctl -u patroni"
}

# Step 14: Final validation
echo "[STEP 14] Final validation checks..."
sleep 3

if systemctl is-active --quiet "$PG_SERVICE"; then
    echo "✔ $PG_SERVICE is active"
else
    echo "❌ $PG_SERVICE NOT active — check: journalctl -u $PG_SERVICE"
fi

if systemctl is-active --quiet "$PATRONI_SERVICE"; then
    echo "✔ $PATRONI_SERVICE is active"
else
    echo "⚠ $PATRONI_SERVICE not active — you may need to inspect /etc/patroni.yml and logs."
fi

echo
echo "=== INSTALL COMPLETE ==="
echo " - Local repo copied to: $TARGET"
echo " - RPMs: $RPM_DIR"
echo " - Wheels: $WHEEL_DIR"
echo " - DNF repo file: $LOCAL_REPO_FILE"
echo
echo "Notes / next steps:"
echo "  * Edit /etc/patroni.yml to match your cluster nodes and replication/auth settings."
echo "  * If PostgreSQL did not start, run: journalctl -u $PG_SERVICE -b"
echo "  * If Patroni did not start, run: journalctl -u $PATRONI_SERVICE -b"
echo "  * If any packages failed to install due to missing dependencies, copy their RPMs into $RPM_DIR on the USB and re-run."
echo
exit 0
