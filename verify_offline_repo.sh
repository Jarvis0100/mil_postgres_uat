#!/usr/bin/env bash
# verify_offline_repo.sh
# Validates Final_repo for offline PG16 + Patroni installation.

set -euo pipefail

REPO_ROOT="${1:-$PWD/Final_repo}"
RPM_DIR="$REPO_ROOT/rpms"
PIP_DIR="$REPO_ROOT/pip_wheels"

echo "=== OFFLINE REPO VALIDATION SCRIPT ==="
echo "Checking Final_repo at: $REPO_ROOT"
echo

# --------------------------- STEP 1 ----------------------------
echo "[STEP 1] Checking RPM repo metadata..."
if [[ -f "$RPM_DIR/repodata/repomd.xml" ]]; then
    echo "✔ repomd.xml found"
else
    echo "❌ ERROR: repomd.xml NOT FOUND in $RPM_DIR/repodata"
    exit 1
fi
echo

# --------------------------- STEP 2 ----------------------------
echo "[STEP 2] Checking required base RPMs..."

REQUIRED_RPMS=(
  haproxy
  keepalived
  python3-pip
  python3-setuptools
  python3-psycopg2
  createrepo_c
  dnf-plugins-core
)

missing_rpm_count=0
for pkg in "${REQUIRED_RPMS[@]}"; do
    if ls "$RPM_DIR" | grep -q "^$pkg"; then
        echo "✔ $pkg found"
    else
        echo "❌ MISSING: $pkg"
        missing_rpm_count=$((missing_rpm_count+1))
    fi
done
echo

# --------------------------- STEP 3 ----------------------------
echo "[STEP 3] Checking PostgreSQL16 RPMs..."

PG16_RPMS=(
  postgresql16
  postgresql16-server
  postgresql16-contrib
  postgresql16-libs
)

pg_missing=0
for pkg in "${PG16_RPMS[@]}"; do
    if ls "$RPM_DIR" | grep -q "^$pkg"; then
        echo "✔ $pkg found"
    else
        echo "❌ MISSING: $pkg"
        pg_missing=$((pg_missing+1))
    fi
done
echo

# --------------------------- STEP 4 ----------------------------
echo "[STEP 4] Checking Python wheels..."

REQUIRED_WHEELS=(
  patroni-4.0.7
  ydiff-1.2
  click
  py_consul
  psutil
  pyyaml
  python_dateutil
  urllib3
  requests
  six
  certifi
  charset_normalizer
  idna
)

wheel_missing=0
for wheel in "${REQUIRED_WHEELS[@]}"; do
    if ls "$PIP_DIR" | grep -qi "^$wheel"; then
        echo "✔ Wheel: $wheel found"
    else
        echo "❌ MISSING wheel: $wheel"
        wheel_missing=$((wheel_missing+1))
    fi
done
echo

# --------------------------- FINAL SUMMARY ----------------------------

echo "=== FINAL SUMMARY ==="

if [[ "$missing_rpm_count" -eq 0 ]]; then
    echo "✔ All required base RPMs present"
else
    echo "❌ Missing $missing_rpm_count base RPM(s)"
fi

if [[ "$pg_missing" -eq 0 ]]; then
    echo "✔ All PostgreSQL16 RPMs present"
else
    echo "❌ Missing $pg_missing PostgreSQL16 RPM(s)"
fi

if [[ "$wheel_missing" -eq 0 ]]; then
    echo "✔ All required Python wheels present"
else
    echo "❌ Missing $wheel_missing Python wheel(s)"
fi
echo

# -------------------------- DECISION ----------------------------
if [[ "$missing_rpm_count" -eq 0 && "$pg_missing" -eq 0 && "$wheel_missing" -eq 0 ]]; then
    echo "🎉 SUCCESS: Offline repo is COMPLETE and ready for installation!"
    exit 0
else
    echo "⚠ Repo NOT complete. Fix missing items before installation."
    exit 2
fi

