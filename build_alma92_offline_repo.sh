#!/bin/bash
set -e

echo "=== OFFLINE REPO BUILDER — FINAL FIXED VERSION ==="

WORKDIR="$(pwd)/Final_repo"
RPM_DIR="$WORKDIR/rpms"
PIP_DIR="$WORKDIR/pip_wheels"
LOGFILE="$(pwd)/build_alma92_repo.log"

mkdir -p "$RPM_DIR" "$PIP_DIR"

log() { echo "[ $(date +'%F %T') ] $1" | tee -a "$LOGFILE"; }

#############################################
# 🔥 STEP -1 — DISABLE ALL PGDG TESTING REPOS
#############################################

log "STEP -1: Hard-disabling ALL PGDG testing repos BEFORE ANY dnf usage"

# Disable testing repos directly via sed (safe even if file changes)
sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/pgdg-redhat-all.repo || true

# Extra hard-disable
for r in pgdg*-testing* pgdg*-updates-testing* pgdg*-beta*; do
    dnf config-manager --set-disabled "$r" >/dev/null 2>&1 || true
done

log "All PGDG testing repos disabled."

#############################################
# STEP 0 — Install needed base tools
#############################################
log "STEP 0: Installing base tools (this will NOT hit testing repos now)"

dnf clean all -y
dnf makecache -y

dnf install -y dnf-plugins-core createrepo_c python3-pip python3-setuptools

pip3 install wheel >/dev/null 2>&1 || true

#############################################
# STEP 1 — Enable proper PGDG repo
#############################################
log "STEP 1: Installing PGDG repo (stable only)"

rpm -Uvh https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true

log "Reset & disable stock PostgreSQL module"
dnf -y module reset postgresql
dnf -y module disable postgresql

#############################################
# STEP 2 — Final cleanup of PGDG repos
#############################################
log "STEP 2: Hard disable testing repos AGAIN (safety)"

sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/pgdg-redhat-all.repo || true
dnf config-manager --set-disabled pgdg*-testing* >/dev/null 2>&1 || true

dnf clean all -y
dnf makecache -y

#############################################
# STEP 3 — Download required RPM packages
#############################################
log "STEP 3: Downloading RPM packages"

PKGS=(
    postgresql16
    postgresql16-server
    postgresql16-contrib
    postgresql16-libs
    python3-devel
    python3-psycopg2
    python3-pip
    python3-setuptools
    createrepo_c
    dnf-plugins-core
    haproxy
    keepalived
)

for pkg in "${PKGS[@]}"; do
    log "Downloading: $pkg"
    if ! dnf download --resolve "$pkg" --destdir "$RPM_DIR"; then
        log "WARNING: Failed to download $pkg"
    fi
done

#############################################
# STEP 4 — ydiff fix
#############################################
log "STEP 4: ydiff wheel fix"

if [[ ! -f "$PIP_DIR/ydiff-1.2-py3-none-any.whl" ]]; then
    pip3 wheel ydiff==1.2 -w "$PIP_DIR"
fi

#############################################
# STEP 5 — Python dependency wheels
#############################################
log "STEP 5: Downloading Patroni wheels"

pip3 download patroni==4.0.7 --no-deps -d "$PIP_DIR"

pip3 download --only-binary=:all: \
    click py-consul psutil PyYAML python-dateutil urllib3 requests six certifi charset-normalizer idna \
    -d "$PIP_DIR"

#############################################
# STEP 7 — Repo metadata creation
#############################################

createrepo_c "$RPM_DIR"
ln -sf "$RPM_DIR" "$WORKDIR/repo"

#############################################
# STEP 8 — Final summary
#############################################
log "BUILD COMPLETE"
echo "Final Repo: $WORKDIR"
echo "RPMs stored in: $RPM_DIR"
echo "Python wheels: $PIP_DIR"

