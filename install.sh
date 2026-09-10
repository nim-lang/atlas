#!/bin/bash

set -eu

ATLAS_REPO_URL="${ATLAS_REPO_URL:-https://github.com/nim-lang/atlas.git}"
ATLAS_INSTALL_DIR="${ATLAS_INSTALL_DIR:-$HOME/.nimble/bin}"
ATLAS_REF="${ATLAS_REF:-}"
ATLAS_TMP_ROOT="${ATLAS_TMP_ROOT:-${TMP:-/tmp}}"
ATLAS_GITHUB_REPO="${ATLAS_GITHUB_REPO:-nim-lang/atlas}"
ATLAS_WINDOWS_DLLS_URL="${ATLAS_WINDOWS_DLLS_URL:-https://nim-lang.org/download/windeps.zip}"

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

windows_runtime_files() {
  case "$1" in
    atlas-windows-amd64.zip)
      printf '%s\n' cacert.pem libcrypto-1_1-x64.dll libssl-1_1-x64.dll
      ;;
    atlas-windows-i386.zip)
      printf '%s\n' cacert.pem libcrypto-1_1.dll libssl-1_1.dll
      ;;
    *)
      return 1
      ;;
  esac
}

windows_runtime_available() {
  local source_dir="$1"
  local archive="$2"
  local runtime_file
  local source_file

  while IFS= read -r runtime_file; do
    source_file="$(find "$source_dir" -type f -name "$runtime_file" -print -quit)"
    if [ -z "$source_file" ]; then
      return 1
    fi
  done < <(windows_runtime_files "$archive")
  return 0
}

copy_windows_runtime() {
  local source_dir="$1"
  local target_dir="$2"
  local archive="$3"
  local runtime_file
  local source_file

  while IFS= read -r runtime_file; do
    source_file="$(find "$source_dir" -type f -name "$runtime_file" -print -quit)"
    if ! cp "$source_file" "$target_dir/$runtime_file"; then
      return 1
    fi
  done < <(windows_runtime_files "$archive")
  return 0
}

ensure_windows_runtime() {
  local source_dir="$1"
  local target_dir="$2"
  local archive="$3"
  local runtime_archive
  local runtime_dir

  case "$archive" in
    atlas-windows-amd64.zip | atlas-windows-i386.zip) ;;
    *) return 0 ;;
  esac

  if windows_runtime_available "$source_dir" "$archive"; then
    copy_windows_runtime "$source_dir" "$target_dir" "$archive"
    return 0
  fi

  if ! has_cmd curl || ! has_cmd unzip; then
    return 1
  fi

  echo "install.sh: release is missing Windows SSL runtime files; downloading Nim support files" >&2
  runtime_archive="$ATLAS_TMP_DIR/windeps.zip"
  runtime_dir="$ATLAS_TMP_DIR/windows-runtime"
  if ! curl -fL "$ATLAS_WINDOWS_DLLS_URL" -o "$runtime_archive"; then
    return 1
  fi
  if ! mkdir -p "$runtime_dir"; then
    return 1
  fi
  if ! unzip -q "$runtime_archive" -d "$runtime_dir"; then
    return 1
  fi
  if ! windows_runtime_available "$runtime_dir" "$archive"; then
    return 1
  fi
  copy_windows_runtime "$runtime_dir" "$target_dir" "$archive"
}

install_release_archive() {
  local archive
  local release_base_url
  local archive_path
  local extract_dir
  local atlas_bin
  local atlas_run_bin
  local installed_atlas
  local installed_atlas_run

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
  atlas_run_bin="$(find "$extract_dir" -type f \( -name atlas-run -o -name atlas-run.exe \) | head -n 1)"
  if [ -z "$atlas_run_bin" ]; then
    echo "install.sh: release asset did not contain atlas-run; falling back to building from source" >&2
    return 1
  fi

  mkdir -p "$ATLAS_INSTALL_DIR"
  case "$atlas_bin" in
    *.exe) installed_atlas="$ATLAS_INSTALL_DIR/atlas.exe" ;;
    *) installed_atlas="$ATLAS_INSTALL_DIR/atlas" ;;
  esac
  case "$atlas_run_bin" in
    *.exe) installed_atlas_run="$ATLAS_INSTALL_DIR/atlas-run.exe" ;;
    *) installed_atlas_run="$ATLAS_INSTALL_DIR/atlas-run" ;;
  esac
  rm -f "$ATLAS_INSTALL_DIR/atlas" "$ATLAS_INSTALL_DIR/atlas.exe" \
    "$ATLAS_INSTALL_DIR/atlas-run" "$ATLAS_INSTALL_DIR/atlas-run.exe"
  cp "$atlas_bin" "$installed_atlas"
  cp "$atlas_run_bin" "$installed_atlas_run"
  chmod +x "$installed_atlas" "$installed_atlas_run"
  if ! ensure_windows_runtime "$extract_dir" "$ATLAS_INSTALL_DIR" "$archive"; then
    echo "install.sh: required Windows runtime files are unavailable; falling back to building from source" >&2
    return 1
  fi

  echo "install.sh: installed atlas to $installed_atlas" >&2
  echo "install.sh: installed atlas-run to $installed_atlas_run" >&2
  if ! "$installed_atlas" --version; then
    echo "install.sh: atlas failed to start; required runtime files may be missing" >&2
    return 1
  fi
  if ! "$installed_atlas_run" --version; then
    echo "install.sh: atlas-run failed to start; required runtime files may be missing" >&2
    return 1
  fi
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
  local source_atlas
  local source_atlas_run
  local installed_atlas
  local installed_atlas_run
  local windows_archive
  local nim_bin_dir

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

  source_atlas="bin/atlas"
  source_atlas_run="bin/atlas-run"
  if [ ! -f "$source_atlas" ] && [ -f "bin/atlas.exe" ]; then
    source_atlas="bin/atlas.exe"
  fi
  if [ ! -f "$source_atlas_run" ] && [ -f "bin/atlas-run.exe" ]; then
    source_atlas_run="bin/atlas-run.exe"
  fi
  if [ ! -f "$source_atlas" ] || [ ! -f "$source_atlas_run" ]; then
    echo "install.sh: build did not produce atlas and atlas-run" >&2
    return 1
  fi

  mkdir -p "$ATLAS_INSTALL_DIR"
  case "$source_atlas" in
    *.exe) installed_atlas="$ATLAS_INSTALL_DIR/atlas.exe" ;;
    *) installed_atlas="$ATLAS_INSTALL_DIR/atlas" ;;
  esac
  case "$source_atlas_run" in
    *.exe) installed_atlas_run="$ATLAS_INSTALL_DIR/atlas-run.exe" ;;
    *) installed_atlas_run="$ATLAS_INSTALL_DIR/atlas-run" ;;
  esac
  rm -f "$ATLAS_INSTALL_DIR/atlas" "$ATLAS_INSTALL_DIR/atlas.exe" \
    "$ATLAS_INSTALL_DIR/atlas-run" "$ATLAS_INSTALL_DIR/atlas-run.exe"
  cp "$source_atlas" "$installed_atlas"
  cp "$source_atlas_run" "$installed_atlas_run"
  chmod +x "$installed_atlas" "$installed_atlas_run"

  windows_archive="$(detect_release_archive || true)"
  if [ -n "$windows_archive" ]; then
    nim_bin_dir="$(dirname "$(command -v nim)")"
    if ! ensure_windows_runtime "$nim_bin_dir" "$ATLAS_INSTALL_DIR" "$windows_archive"; then
      echo "install.sh: required Windows runtime files are unavailable" >&2
      return 1
    fi
  fi

  echo "install.sh: installed atlas to $installed_atlas" >&2
  echo "install.sh: installed atlas-run to $installed_atlas_run" >&2
  if command -v "$installed_atlas" >/dev/null 2>&1; then
    if ! "$installed_atlas" --version; then
      return 1
    fi
    if ! "$installed_atlas_run" --version; then
      return 1
    fi
  else
    if ! "$installed_atlas" --version; then
      return 1
    fi
    if ! "$installed_atlas_run" --version; then
      return 1
    fi
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
