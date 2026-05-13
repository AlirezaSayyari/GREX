#!/bin/bash

set -e

REPO_USER="AlirezaSayyari"
REPO_NAME="GREX"
BRANCH="main"
TMPDIR=$(mktemp -d)

run_as_root() {
    if [ "$EUID" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for bootstrap installation. Install curl and retry."
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "tar is required for bootstrap installation. Install tar and retry."
    exit 1
fi

SCRIPT_URL="https://github.com/$REPO_USER/$REPO_NAME/archive/refs/heads/$BRANCH.tar.gz"

echo "Downloading $REPO_USER/$REPO_NAME ($BRANCH)..."
cd "$TMPDIR"
curl -fsSL "$SCRIPT_URL" | tar -xz

REPO_DIR="$TMPDIR/$REPO_NAME-$BRANCH"
if [ ! -d "$REPO_DIR" ]; then
    echo "Failed to download repository archive."
    exit 1
fi

cd "$REPO_DIR"

echo "Installing GRE Tunnel helper scripts..."
run_as_root bash install.sh

echo "Running setup wizard..."
if [ -r /dev/tty ]; then
    run_as_root bash setup.sh </dev/tty
else
    run_as_root bash setup.sh
fi

echo "Bootstrap complete."
echo "If you need the helper manager later, run: sudo grex"
