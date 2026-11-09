#!/usr/bin/env bash
# KSXNode Node installer.
#
# Usage (machine mode):
#   curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
#     | sudo bash -s -- --mode machine --panel https://panel.example.com \
#         --token MACHINE_TOKEN --machine-id 1
#
# Usage (single node):
#   curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
#     | sudo bash -s -- --mode node --panel https://panel.example.com \
#         --token NODE_TOKEN --node-id 1
#
# The script installs /usr/local/bin/xboard-node, writes
# /etc/xboard-node/config.yml and creates a systemd service.
set -Eeuo pipefail

MODE="node"
PANEL=""
TOKEN=""
NODE_ID=""
MACHINE_ID=""
KERNEL="singbox"
DOMAIN=""
VERSION="latest"
FORCE=0

REPO="KSXNode/xboard-node-install"
INSTALL_DIR="/etc/xboard-node"
CONFIG="$INSTALL_DIR/config.yml"
BIN="/usr/local/bin/xboard-node"
SERVICE="/etc/systemd/system/xboard-node.service"

log()  { printf '\033[1;32m[KSXNode]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[KSXNode]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[KSXNode]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
KSXNode Node installer

Options:
  --mode node|machine   Install mode (default: node)
  --panel URL           Panel URL, e.g. https://panel.example.com
  --token TOKEN         Node token (node mode) or machine token (machine mode)
  --node-id ID          Node ID (node mode)
  --machine-id ID       Machine ID (machine mode)
  --kernel NAME         Kernel type (default: singbox)
  --domain DOMAIN       Certificate domain (default: panel hostname)
  --version TAG         Release tag (default: latest)
  --force               Overwrite an existing config
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --panel) PANEL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --node-id) NODE_ID="${2:-}"; shift 2 ;;
    --machine-id) MACHINE_ID="${2:-}"; shift 2 ;;
    --kernel) KERNEL="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Please run as root (or use sudo)."
[ -n "$PANEL" ] || die "--panel is required"
[ -n "$TOKEN" ] || die "--token is required"
PANEL="${PANEL%/}"
case "$MODE" in
  node) [ -n "$NODE_ID" ] || die "--node-id is required in node mode" ;;
  machine) [ -n "$MACHINE_ID" ] || die "--machine-id is required in machine mode" ;;
  *) die "--mode must be node or machine" ;;
esac

# ---- detect architecture ------------------------------------------------
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv7|armhf) ARCH="armv7" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
log "architecture: $ARCH"

if [ -z "$DOMAIN" ]; then
  DOMAIN=$(printf '%s' "$PANEL" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
fi

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
need curl
need gzip
if ! command -v systemctl >/dev/null 2>&1; then
  die "systemd is required (systemctl not found)"
fi

# ---- download binary ----------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/xboard-node-$ARCH.gz"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/xboard-node-$ARCH.gz"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "downloading $URL"
curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/node.gz" "$URL" \
  || die "Download failed: $URL"
gzip -dc "$TMP/node.gz" > "$TMP/xboard-node"
chmod 755 "$TMP/xboard-node"

# ---- install binary -----------------------------------------------------
install -m 755 "$TMP/xboard-node" "$BIN"
log "installed $BIN"

# ---- write config -------------------------------------------------------
mkdir -p "$INSTALL_DIR"
if [ -f "$CONFIG" ] && [ "$FORCE" -eq 0 ]; then
  BAK="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG" "$BAK"
  warn "existing config backed up to $BAK"
fi

umask 077
{
  echo "panel:"
  echo "  url: \"$PANEL\""
  if [ "$MODE" = "machine" ]; then
    echo
    echo "machine:"
    echo "  machine_id: $MACHINE_ID"
    echo "  token: \"$TOKEN\""
  else
    echo "  token: \"$TOKEN\""
    echo "  node_id: $NODE_ID"
  fi
  echo
  echo "kernel:"
  echo "  type: \"$KERNEL\""
  echo "  config_dir: \"$INSTALL_DIR\""
  echo "  log_level: \"warn\""
  echo
  echo "cert:"
  echo "  cert_mode: \"self\""
  echo "  domain: \"$DOMAIN\""
  echo
  echo "log:"
  echo "  level: \"info\""
  echo "  output: \"stdout\""
} > "$CONFIG"
chmod 600 "$CONFIG"
log "wrote $CONFIG"

# ---- systemd service ----------------------------------------------------
cat > "$SERVICE" <<'EOF'
[Unit]
Description=KSXNode Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/config.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xboard-node >/dev/null 2>&1 || true
systemctl restart xboard-node

sleep 2
if systemctl is-active --quiet xboard-node; then
  log "KSXNode Node is running."
  log "View logs: journalctl -u xboard-node -f"
else
  warn "Service is not active. Recent logs:"
  journalctl -u xboard-node -n 30 --no-pager || true
  exit 1
fi
