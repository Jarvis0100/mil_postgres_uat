#!/usr/bin/env bash
set -euo pipefail

### CONFIG (DO NOT CHANGE UNLESS YOU MOVE DIRS)
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
FINAL_REPO="$BASE_DIR/Final_repo"
RPM_DIR="$FINAL_REPO/rpms"
WHEEL_DIR="$FINAL_REPO/pip_wheels"
LOG="/var/log/offline_pg16_patroni_install.log"

exec > >(tee -a "$LOG") 2>&1

echo "=== OFFLINE PostgreSQL16 + Patroni INSTALLER ==="
echo "Using repo: $FINAL_REPO"
echo "Logfile: $LOG"
echo

### STEP 0: Basic validation
echo "[STEP 0] Validating directory layout..."
for d in "$FINAL_REPO" "$RPM_DIR" "$WHEEL_DIR"; do
  [[ -d "$d" ]] || { echo "❌ Missing $d"; exit 1; }
done

[[ -f "$RPM_DIR/repodata/repomd.xml" ]] || {
  echo "❌ Missing repodata/repomd.xml"
  exit 1
}
echo "✔ Repo layout OK"

### STEP 1: Create LOCAL dnf repo
echo "[STEP 1] Creating local dnf repo..."
cat >/etc/yum.repos.d/local-offline.repo <<EOF
[local-offline]
name=Local Offline Repo
baseurl=file://$RPM_DIR
enabled=1
gpgcheck=0
EOF

dnf clean all
dnf --disablerepo="*" --enablerepo="local-offline" makecache

### STEP 2: Disable stock PostgreSQL module (CRITICAL)
echo "[STEP 2] Disabling stock PostgreSQL module..."
dnf module reset postgresql -y
dnf module disable postgresql -y

### STEP 3: Verify required RPMs exist in repo
echo "[STEP 3] Verifying required RPMs..."
REQ_RPMS=(
  postgresql16
  postgresql16-server
  postgresql16-contrib
  postgresql16-libs
  python3-pip
  python3-setuptools
  python3-psycopg2
  haproxy
  keepalived
)

for p in "${REQ_RPMS[@]}"; do
  dnf --disablerepo="*" --enablerepo="local-offline" repoquery "$p" >/dev/null \
    || { echo "❌ Missing RPM: $p"; exit 1; }
  echo "✔ $p"
done

### STEP 4: Install RPMs (OFFLINE)
echo "[STEP 4] Installing RPMs..."
dnf --disablerepo="*" --enablerepo="local-offline" install -y \
  postgresql16 \
  postgresql16-server \
  postgresql16-contrib \
  postgresql16-libs \
  python3-pip \
  python3-setuptools \
  python3-psycopg2 \
  haproxy \
  keepalived

### STEP 5: Initialize PostgreSQL 16
echo "[STEP 5] Initializing PostgreSQL 16..."
/usr/pgsql-16/bin/postgresql-16-setup initdb || true
systemctl enable postgresql-16
systemctl start postgresql-16

### STEP 6: Install Patroni (OFFLINE PIP)
echo "[STEP 6] Installing Patroni via offline wheels..."
pip3 install --no-index --find-links "$WHEEL_DIR" patroni==4.0.7

### STEP 7: Create Patroni service
echo "[STEP 7] Creating Patroni systemd service..."
cat >/etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network.target postgresql-16.service

[Service]
User=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni.yml
Restart=always
LimitNOFILE=10240

[Install]
WantedBy=multi-user.target
EOF

### STEP 8: Minimal Patroni config
if [[ ! -f /etc/patroni.yml ]]; then
cat >/etc/patroni.yml <<EOF
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
EOF
chown postgres:postgres /etc/patroni.yml
fi

systemctl daemon-reload
systemctl enable patroni
systemctl start patroni

### STEP 9: Final verification
echo
echo "=== FINAL STATUS ==="
systemctl is-active postgresql-16 && echo "✔ PostgreSQL16 running"
systemctl is-active patroni && echo "✔ Patroni running"

echo
echo "🎉 OFFLINE INSTALL COMPLETE"
echo "Logs: $LOG"
