#!/bin/sh

set -eu

ATLAS_REPO_URL="${ATLAS_REPO_URL:-https://github.com/nim-lang/atlas.git}"
ATLAS_INSTALL_DIR="${ATLAS_INSTALL_DIR:-$HOME/.nimble/bin}"
ATLAS_REF="${ATLAS_REF:-}"
ATLAS_TMP_ROOT="${ATLAS_TMP_ROOT:-${TMP:-/tmp}}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "install.sh: missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  if [ -n "${ATLAS_TMP_DIR:-}" ] && [ -d "$ATLAS_TMP_DIR" ]; then
    rm -rf "$ATLAS_TMP_DIR"
  fi
}

need_cmd git
need_cmd nim
need_cmd mktemp
need_cmd cp
need_cmd mkdir

ATLAS_TMP_DIR="$(mktemp -d "$ATLAS_TMP_ROOT/atlas-install.XXXXXX")"
trap cleanup EXIT INT TERM

echo "install.sh: cloning atlas into $ATLAS_TMP_DIR" >&2
if [ -n "$ATLAS_REF" ]; then
  git clone --depth 1 --branch "$ATLAS_REF" "$ATLAS_REPO_URL" "$ATLAS_TMP_DIR"
else
  git clone --depth 1 "$ATLAS_REPO_URL" "$ATLAS_TMP_DIR"
fi

cd "$ATLAS_TMP_DIR"

echo "install.sh: building atlas" >&2
nim buildRelease

mkdir -p "$ATLAS_INSTALL_DIR"
if [ -e "$ATLAS_INSTALL_DIR/atlas" ] || [ -L "$ATLAS_INSTALL_DIR/atlas" ]; then
  rm -f "$ATLAS_INSTALL_DIR/atlas"
fi
cp "bin/atlas" "$ATLAS_INSTALL_DIR/atlas"
chmod +x "$ATLAS_INSTALL_DIR/atlas"

echo "install.sh: installed atlas to $ATLAS_INSTALL_DIR/atlas" >&2
if command -v "$ATLAS_INSTALL_DIR/atlas" >/dev/null 2>&1; then
  "$ATLAS_INSTALL_DIR/atlas" --version
else
  "$ATLAS_INSTALL_DIR/atlas" --version
  case ":$PATH:" in
    *":$ATLAS_INSTALL_DIR:"*) ;;
    *)
      echo "install.sh: add $ATLAS_INSTALL_DIR to PATH to run atlas directly" >&2
      ;;
  esac
fi
