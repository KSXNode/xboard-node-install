#!/bin/sh
# KSXNode Node installer.
#
# Usage (machine mode):
#   curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
#     | sudo sh -s -- --mode machine --panel https://panel.example.com \
#         --token MACHINE_TOKEN --machine-id 1
#
# Usage (single node):
#   curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
#     | sudo sh -s -- --mode node --panel https://panel.example.com \
#         --token NODE_TOKEN --node-id 1
#
# Usage (OpenWrt / ImmortalWrt, run as root):
#   wget -qO- https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
#     | sh -s -- --mode machine --panel https://panel.example.com \
#         --token MACHINE_TOKEN --machine-id 1
#
# The script installs /usr/local/bin/xboard-node, writes
# /etc/xboard-node/config.yml and creates a systemd unit or an OpenWrt
# procd service, depending on the init system it detects.
set -eu

MODE="node"
PANEL=""
TOKEN=""
NODE_ID=""
MACHINE_ID=""
KERNEL="singbox"
DOMAIN=""
VERSION="latest"
SERVICE_MODE="auto"
FORCE=0

REPO="KSXNode/xboard-node-install"
INSTALL_DIR="/etc/xboard-node"
CONFIG="$INSTALL_DIR/config.yml"
BIN="/usr/local/bin/xboard-node"
UNIT="/etc/systemd/system/xboard-node.service"
INITD="/etc/init.d/xboard-node"

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
  --service MODE        Init system: auto|systemd|procd|none (default: auto)
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
    --service) SERVICE_MODE="${2:-}"; shift 2 ;;
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

# ---- detect init system -------------------------------------------------
detect_service() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    echo systemd
  elif [ -f /etc/rc.common ]; then
    echo procd
  else
    echo none
  fi
}

if [ "$SERVICE_MODE" = "auto" ]; then
  SERVICE_MODE=$(detect_service)
fi
case "$SERVICE_MODE" in
  systemd|procd|none) ;;
  *) die "--service must be auto, systemd, procd or none" ;;
esac
log "init system: $SERVICE_MODE"

if [ -z "$DOMAIN" ]; then
  DOMAIN=$(printf '%s' "$PANEL" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
fi

need() { command -v "$1" >/dev/null 2>&1; }
need gzip || die "Missing required command: gzip"
if ! need curl && ! need wget && ! need uclient-fetch; then
  die "Missing downloader: install curl, or (OpenWrt) opkg update && opkg install ca-bundle"
fi

# ---- download binary ----------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/$REPO/releases/latest/download/xboard-node-$ARCH.gz"
else
  URL="https://github.com/$REPO/releases/download/$VERSION/xboard-node-$ARCH.gz"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() {
  url="$1"
  out="$2"
  if need curl; then
    curl -fsSL --retry 3 --connect-timeout 15 -o "$out" "$url" && return 0
  fi
  if need wget; then
    wget -q -O "$out" "$url" && return 0
  fi
  if need uclient-fetch; then
    uclient-fetch -q -O "$out" "$url" && return 0
  fi
  return 1
}

log "downloading $URL"
fetch "$URL" "$TMP/node.gz" || die "Download failed: $URL
On OpenWrt install ca-bundle first: opkg update && opkg install ca-bundle"
gzip -dc "$TMP/node.gz" > "$TMP/xboard-node" || die "Failed to decompress $TMP/node.gz"
chmod 755 "$TMP/xboard-node"

# ---- install binary -----------------------------------------------------
mkdir -p "$(dirname "$BIN")"
if command -v install >/dev/null 2>&1; then
  install -m 755 "$TMP/xboard-node" "$BIN"
else
  cp "$TMP/xboard-node" "$BIN"
  chmod 755 "$BIN"
fi
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

# ---- service ------------------------------------------------------------
install_systemd() {
  mkdir -p /etc/systemd/system
  cat > "$UNIT" <<'EOF'
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
}

install_procd() {
  mkdir -p /etc/init.d /etc/rc.d
  cat > "$INITD" <<'EOF'
#!/bin/sh /etc/rc.common
# Managed by the KSXNode installer.

START=99
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/local/bin/xboard-node -c /etc/xboard-node/config.yml
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param limits nofile="1048576 1048576"
	procd_close_instance
}

reload_service() {
	stop
	start
}
EOF
  chmod 755 "$INITD"
  "$INITD" enable >/dev/null 2>&1 || true
  "$INITD" restart
}

case "$SERVICE_MODE" in
  systemd) install_systemd ;;
  procd) install_procd ;;
  none)
    warn "no init system selected; start manually: $BIN -c $CONFIG"
    exit 0
    ;;
esac

# ---- verify -------------------------------------------------------------
sleep 2
RUNNING=0
if [ "$SERVICE_MODE" = "systemd" ]; then
  systemctl is-active --quiet xboard-node && RUNNING=1
elif [ "$SERVICE_MODE" = "procd" ]; then
  if command -v pidof >/dev/null 2>&1; then
    pidof xboard-node >/dev/null 2>&1 && RUNNING=1
  else
    ps w 2>/dev/null | grep -q "[x]board-node -c" && RUNNING=1
  fi
else
  ps 2>/dev/null | grep -q "[x]board-node -c" && RUNNING=1
fi

if [ "$RUNNING" -eq 1 ]; then
  log "KSXNode Node is running."
  if [ "$SERVICE_MODE" = "systemd" ]; then
    log "View logs: journalctl -u xboard-node -f"
  elif [ "$SERVICE_MODE" = "procd" ]; then
    log "View logs: logread | grep xboard-node"
  fi
else
  warn "Service is not active. Recent logs:"
  if [ "$SERVICE_MODE" = "systemd" ]; then
    journalctl -u xboard-node -n 30 --no-pager || true
  elif [ "$SERVICE_MODE" = "procd" ]; then
    logread 2>/dev/null | grep xboard-node | tail -n 30 || true
  fi
  exit 1
fi
