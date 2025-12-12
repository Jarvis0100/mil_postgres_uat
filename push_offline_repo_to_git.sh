#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
REPO_DIR="/home/jarvis0100/Public/postgres_install"
OFFLINE_DIR="$REPO_DIR/Final_repo"
ARCHIVE="Final_repo_$(date +%Y%m%d_%H%M).tar.gz"
REMOTE_URL="https://github.com/Jarvis0100/mil_postgres_uat.git"

echo "=== Starting Offline Repo Packaging & Git Upload ==="

# --- Step 1: Validate Final_repo Exists ---
if [[ ! -d "$OFFLINE_DIR" ]]; then
    echo "ERROR: $OFFLINE_DIR does not exist!"
    exit 1
fi

cd "$REPO_DIR"

# --- Step 2: Create tar.gz package ---
echo "Packaging Final_repo into: $ARCHIVE"
tar -czvf "$ARCHIVE" Final_repo/

# --- Step 3: Initialize Git repo (idempotent) ---
if [[ ! -d ".git" ]]; then
    echo "Initializing new Git repository..."
    git init
else
    echo "Git repo already initialized — continuing."
fi

# --- Step 4: Add archive + all scripts ---
echo "Adding files to Git..."
git add "$ARCHIVE"
git add *.sh || true
git add README.md || true

# --- Step 5: Commit changes ---
echo "Committing..."
git commit -m "Added offline repo package $(date)"

# --- Step 6: Set main branch ---
git branch -M main

# --- Step 7: Add remote if missing ---
if ! git remote | grep -q origin; then
    echo "Adding remote origin: $REMOTE_URL"
    git remote add origin "$REMOTE_URL"
else
    echo "Remote origin already exists — skipping add."
fi

# --- Step 8: Push to GitHub ---
echo "Pushing to GitHub..."
git push -u origin main --force

echo "=== DONE ==="
echo "Uploaded archive: $ARCHIVE"

