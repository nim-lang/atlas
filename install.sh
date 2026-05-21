#!/bin/bash

set -eu

ATLAS_REPO_URL="${ATLAS_REPO_URL:-https://github.com/nim-lang/atlas.git}"
ATLAS_INSTALL_DIR="${ATLAS_INSTALL_DIR:-$HOME/.nimble/bin}"
ATLAS_REF="${ATLAS_REF:-}"
ATLAS_TMP_ROOT="${ATLAS_TMP_ROOT:-${TMP:-/tmp}}"
ATLAS_GITHUB_REPO="${ATLAS_GITHUB_REPO:-nim-lang/atlas}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "install.sh: missing required command: $1" >&2
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  if [ -n "${ATLAS_TMP_DIR:-}" ] && [ -d "$ATLAS_TMP_DIR" ]; then
    rm -rf "$ATLAS_TMP_DIR"
  fi
}

need_cmd mktemp
need_cmd cp
need_cmd mkdir

ATLAS_TMP_DIR="$(mktemp -d "$ATLAS_TMP_ROOT/atlas-install.XXXXXX")"
trap cleanup EXIT INT TERM

detect_release_archive() {
  local os
  local arch

  os="$(uname -s 2>/dev/null || true)"
  arch="$(uname -m 2>/dev/null || true)"

  case "$os" in
    Linux)
      case "$arch" in
        x86_64 | amd64) echo "atlas-linux-amd64.tar.gz" ;;
        aarch64 | arm64) echo "atlas-linux-arm64.tar.gz" ;;
        armv7l | armv7* | armhf | arm) echo "atlas-linux-arm32.tar.gz" ;;
        *) return 1 ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        x86_64 | amd64 | arm64 | aarch64) echo "atlas-macos-universal.tar.gz" ;;
        *) return 1 ;;
      esac
      ;;
    MINGW* | MSYS* | CYGWIN*)
      case "$arch" in
        x86_64 | amd64) echo "atlas-windows-amd64.zip" ;;
        i386 | i686 | x86) echo "atlas-windows-i386.zip" ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

github_release_base_url() {
  case "$ATLAS_REPO_URL" in
    https://github.com/*/*.git)
      echo "${ATLAS_REPO_URL%.git}/releases/latest/download"
      ;;
    https://github.com/*/*)
      echo "${ATLAS_REPO_URL%/}/releases/latest/download"
      ;;
    git@github.com:*/*.git)
      local repo
      repo="${ATLAS_REPO_URL#git@github.com:}"
      repo="${repo%.git}"
      echo "https://github.com/$repo/releases/latest/download"
      ;;
    *)
      if [ "$ATLAS_REPO_URL" = "https://github.com/$ATLAS_GITHUB_REPO.git" ]; then
        echo "https://github.com/$ATLAS_GITHUB_REPO/releases/latest/download"
      else
        return 1
      fi
      ;;
  esac
}

install_release_archive() {
  local archive
  local release_base_url
  local archive_path
  local extract_dir
  local atlas_bin
  local installed_atlas

  if [ -n "$ATLAS_REF" ]; then
    return 1
  fi

  archive="$(detect_release_archive)" || return 1
  release_base_url="$(github_release_base_url)" || return 1
  archive_path="$ATLAS_TMP_DIR/$archive"
  extract_dir="$ATLAS_TMP_DIR/release"

  if ! has_cmd curl; then
    return 1
  fi
  if [ "${archive%.zip}" != "$archive" ]; then
    if ! has_cmd unzip; then
      return 1
    fi
  else
    if ! has_cmd tar; then
      return 1
    fi
  fi

  echo "install.sh: downloading latest atlas release asset $archive" >&2
  if ! curl -fL "$release_base_url/$archive" -o "$archive_path"; then
    echo "install.sh: release asset download failed; falling back to building from source" >&2
    return 1
  fi

  mkdir -p "$extract_dir"
  if [ "${archive%.zip}" != "$archive" ]; then
    unzip -q "$archive_path" -d "$extract_dir"
  else
    tar -xzf "$archive_path" -C "$extract_dir"
  fi

  atlas_bin="$(find "$extract_dir" -type f \( -name atlas -o -name atlas.exe \) | head -n 1)"
  if [ -z "$atlas_bin" ]; then
    echo "install.sh: release asset did not contain atlas; falling back to building from source" >&2
    return 1
  fi

  mkdir -p "$ATLAS_INSTALL_DIR"
  case "$atlas_bin" in
    *.exe) installed_atlas="$ATLAS_INSTALL_DIR/atlas.exe" ;;
    *) installed_atlas="$ATLAS_INSTALL_DIR/atlas" ;;
  esac
  rm -f "$ATLAS_INSTALL_DIR/atlas" "$ATLAS_INSTALL_DIR/atlas.exe"
  cp "$atlas_bin" "$installed_atlas"
  chmod +x "$installed_atlas"

  echo "install.sh: installed atlas to $installed_atlas" >&2
  "$installed_atlas" --version
  case ":$PATH:" in
    *":$ATLAS_INSTALL_DIR:"*) ;;
    *)
      echo "install.sh: add $ATLAS_INSTALL_DIR to PATH to run atlas directly" >&2
      ;;
  esac
  return 0
}

install_from_source() {
  local source_dir

  need_cmd git
  need_cmd nim

  source_dir="$ATLAS_TMP_DIR/source"
  echo "install.sh: cloning atlas into $source_dir from $ATLAS_REPO_URL" >&2
  if [ -n "$ATLAS_REF" ]; then
    git clone "$ATLAS_REPO_URL" "$source_dir"
    cd "$source_dir"
    git checkout "$ATLAS_REF"
  else
    git clone --depth 1 "$ATLAS_REPO_URL" "$source_dir"
    cd "$source_dir"
  fi

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
}

if install_release_archive; then
  exit 0
fi

install_from_source
