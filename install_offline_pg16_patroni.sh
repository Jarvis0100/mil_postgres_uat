#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#   OFFLINE INSTALLER FOR POSTGRESQL 16 + PATRONI (FINAL V1)
# ============================================================

REPO_ROOT="/home/jarvis0100/Public/postgres_install/Final_repo"
RPM_DIR="$REPO_ROOT/rpms"
WHEEL_DIR="$REPO_ROOT/pip_wheels"
LOG="/var/log/offline_pg16_patroni_install.log"

echo "=== OFFLINE INSTALLER FOR PostgreSQL16 + Patroni ==="
echo "Log: $LOG"
echo "Using repo: $REPO_ROOT"
echo "====================================================="

exec > >(tee -a "$LOG") 2>&1

# -----------------------------------------------------------
# STEP 1 — Validate directory structure
# -----------------------------------------------------------
echo "[STEP 1] Validating offline repo..."

if [[ ! -d "$RPM_DIR" ]]; then
    echo "❌ ERROR: RPM directory missing: $RPM_DIR"
    exit 1
fi

if [[ ! -d "$WHEEL_DIR" ]]; then
    echo "❌ ERROR: Wheel directory missing: $WHEEL_DIR"
    exit 1
fi

echo "✔ Repo directories found"

# -----------------------------------------------------------
# STEP 2 — Register local DNF repo
# -----------------------------------------------------------
echo "[STEP 2] Registering local/offline DNF repo..."

cat > /etc/yum.repos.d/local-offline.repo <<EOF
[local-offline]
name=Offline Repository
baseurl=file://$RPM_DIR
enabled=1
gpgcheck=0
priority=1
EOF

dnf clean all
dnf --disablerepo="*" --enablerepo="local-offline" makecache

echo "✔ Local DNF repo registered"

# -----------------------------------------------------------
# STEP 3 — Install PostgreSQL16 from offline repo
# -----------------------------------------------------------
echo "[STEP 3] Installing PostgreSQL16 RPM packages..."

dnf --disablerepo="*" \
    --enablerepo="local-offline" \
    install -y \
        postgresql16 \
        postgresql16-server \
        postgresql16-contrib \
        postgresql16-libs

echo "✔ PostgreSQL16 installed"

# -----------------------------------------------------------
# STEP 4 — Initialize PostgreSQL cluster
# -----------------------------------------------------------
echo "[STEP 4] Initializing PostgreSQL16..."

if [[ ! -d /var/lib/pgsql/16 ]]; then
    echo "Creating new PG16 data directory..."
    /usr/pgsql-16/bin/postgresql-16-setup initdb
fi

systemctl enable postgresql-16
systemctl start postgresql-16

echo "✔ PostgreSQL16 started"

# -----------------------------------------------------------
# STEP 5 — Install Patroni from offline wheels
# -----------------------------------------------------------
echo "[STEP 5] Installing Patroni + dependencies using offline wheels..."

pip3 install --no-index --find-links "$WHEEL_DIR" patroni==4.0.7

echo "✔ Patroni installed offline"

# -----------------------------------------------------------
# STEP 6 — Create Patroni systemd service
# -----------------------------------------------------------
echo "[STEP 6] Creating Patroni Service..."

cat > /etc/systemd/system/patroni.service <<EOF
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

echo "✔ Patroni systemd service created"

# -----------------------------------------------------------
# STEP 7 — Create basic Patroni config (minimal)
# -----------------------------------------------------------
echo "[STEP 7] Generating minimal Patroni config..."

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

echo "✔ Patroni config written to /etc/patroni.yml"

# -----------------------------------------------------------
# STEP 8 — Enable & Start Patroni
# -----------------------------------------------------------
echo "[STEP 8] Starting Patroni..."

systemctl enable patroni
systemctl start patroni

sleep 3

systemctl status patroni --no-pager || true

echo "✔ Patroni service started"

# -----------------------------------------------------------
# STEP 9 — Final Verification
# -----------------------------------------------------------
echo "[STEP 9] Final Verification..."

if systemctl is-active --quiet postgresql-16; then
    echo "✔ PostgreSQL16 ACTIVE"
else
    echo "❌ PostgreSQL16 NOT RUNNING"; exit 1
fi

if systemctl is-active --quiet patroni; then
    echo "✔ Patroni ACTIVE"
else
    echo "❌ Patroni NOT RUNNING"; exit 1
fi

echo ""
echo "==================================================="
echo " 🎉 OFFLINE INSTALLATION SUCCESSFUL!"
echo " PostgreSQL 16 + Patroni is fully operational."
echo " Log saved to: $LOG"
echo "==================================================="
