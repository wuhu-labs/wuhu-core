#!/bin/bash
set -euo pipefail

# Wuhu CLI installer
# Usage: curl -fsSL https://raw.githubusercontent.com/wuhu-labs/wuhu-core/main/install.sh | bash
#    or: curl -fsSL https://raw.githubusercontent.com/wuhu-labs/wuhu-core/main/install.sh | bash -s -- --version 0.6.0

REPO="wuhu-labs/wuhu-core"
INSTALL_DIR="$HOME/.wuhu/bin"
VERSION=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Detect platform
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  PLATFORM_OS="linux" ;;
  Darwin) PLATFORM_OS="macos" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64)  PLATFORM_ARCH="x86_64" ;;
  aarch64) PLATFORM_ARCH="arm64" ;;
  arm64)   PLATFORM_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

PLATFORM="${PLATFORM_OS}-${PLATFORM_ARCH}"
ASSET_NAME="wuhu-${PLATFORM}.tar.gz"

# Resolve version
if [[ -z "$VERSION" ]]; then
  echo "Fetching latest release..."
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
fi

if [[ -z "$VERSION" ]]; then
  echo "Error: could not determine latest version"
  exit 1
fi

echo "Installing wuhu ${VERSION} for ${PLATFORM}..."

# Create versioned directory
VERSION_DIR="${INSTALL_DIR}/${VERSION}"
mkdir -p "$VERSION_DIR"

# Download
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET_NAME}"
echo "Downloading ${DOWNLOAD_URL}..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${ASSET_NAME}"

# Extract
tar xzf "${TMP_DIR}/${ASSET_NAME}" -C "$TMP_DIR"

# Install binary
mv "${TMP_DIR}/wuhu" "${VERSION_DIR}/wuhu"
chmod +x "${VERSION_DIR}/wuhu"

# Verify
"${VERSION_DIR}/wuhu" --version || {
  echo "Error: downloaded binary failed verification"
  rm -rf "$VERSION_DIR"
  exit 1
}

# Atomic symlink swap
SYMLINK="${INSTALL_DIR}/wuhu"
TMP_LINK="${INSTALL_DIR}/.wuhu-symlink-$$"
ln -sf "${VERSION}/wuhu" "$TMP_LINK"
mv -f "$TMP_LINK" "$SYMLINK"

echo ""
echo "✓ Installed wuhu ${VERSION} to ${VERSION_DIR}/wuhu"
echo "✓ Symlinked ${SYMLINK} → ${VERSION}/wuhu"

# Check PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
  echo ""
  echo "Add wuhu to your PATH by adding this to your shell profile:"
  echo ""
  SHELL_NAME="$(basename "$SHELL")"
  case "$SHELL_NAME" in
    zsh)  RC_FILE="~/.zshrc" ;;
    bash) RC_FILE="~/.bashrc" ;;
    fish) RC_FILE="~/.config/fish/config.fish" ;;
    *)    RC_FILE="your shell profile" ;;
  esac
  if [[ "$SHELL_NAME" == "fish" ]]; then
    echo "  fish_add_path ${INSTALL_DIR}"
  else
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  fi
  echo ""
  echo "Then restart your shell or run:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi
