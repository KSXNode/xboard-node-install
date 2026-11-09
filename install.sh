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
PORTS=""
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
  --service MODE        Init system: auto|systemd|procd|asuswrt|none (default: auto)
  --ports RANGE         Asuswrt only: open this iptables port range, e.g. 7410:7413
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
    --ports) PORTS="${2:-}"; shift 2 ;;
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
  elif [ -d /jffs ] && [ -w /jffs ] && [ -d /data ]; then
    echo asuswrt
  else
    echo none
  fi
}

if [ "$SERVICE_MODE" = "auto" ]; then
  SERVICE_MODE=$(detect_service)
fi
case "$SERVICE_MODE" in
  systemd|procd|asuswrt|none) ;;
  *) die "--service must be auto, systemd, procd, asuswrt or none" ;;
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

# ---- Asuswrt / Broadcom routers (/jffs persistent, /tmp runtime) --------
install_asuswrt() {
  PERSIST=/jffs/xboard-node
  RUN=/tmp/xboard-node
  GZ="$PERSIST/xboard-node-$ARCH.gz"
  CFG_P="$PERSIST/config.yml"
  START="$PERSIST/start.sh"
  HOOK=/data/startup.sh

  mkdir -p "$PERSIST" "$RUN/data" /data || die "cannot create install directories"

  # persistent compressed binary
  if [ ! -s "$GZ" ] || [ "$FORCE" -eq 1 ]; then
    log "downloading $URL"
    TMPGZ="$GZ.tmp.$$"
    fetch "$URL" "$TMPGZ" || { rm -f "$TMPGZ"; die "Download failed: $URL"; }
    mv -f "$TMPGZ" "$GZ" || die "cannot write $GZ"
    log "installed $GZ"
  else
    log "existing archive kept: $GZ (use --force to replace)"
  fi

  # persistent config
  if [ -f "$CFG_P" ] && [ "$FORCE" -eq 0 ]; then
    BAK="$CFG_P.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CFG_P" "$BAK" 2>/dev/null || true
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
    echo "  config_dir: \"$RUN/data\""
    echo "  log_level: \"warn\""
    echo
    echo "cert:"
    echo "  cert_mode: \"self\""
    echo "  domain: \"$DOMAIN\""
    echo
    echo "log:"
    echo "  level: \"info\""
    echo "  output: \"stdout\""
  } > "$CFG_P"
  chmod 600 "$CFG_P"
  log "wrote $CFG_P"

  # persistent start script
  cat > "$START" <<'STARTEOF'
#!/bin/sh
# KSXNode xboard-node bootstrap for ASUS / Broadcom routers (Asuswrt).
# Persistent files live in /jffs; the binary is decompressed to /tmp on boot.
set -u
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

PERSIST=/jffs/xboard-node
GZ="$PERSIST/xboard-node.gz"
CFG_P="$PERSIST/config.yml"
RUN=/tmp/xboard-node
BIN="$RUN/xboard-node"
CFG="$RUN/config.yml"
PID="$RUN/xboard-node.pid"
LOG="$RUN/xboard-node.log"
LOCK="$RUN/.start.lock"
PORT_RANGE=""

mkdir -p "$RUN" "$RUN/data" "$PERSIST"

# open the configured node ports (idempotent, additive)
for proto in tcp udp; do
    [ -n "$PORT_RANGE" ] || break
    iptables -C INPUT -p "$proto" --dport "$PORT_RANGE" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p "$proto" --dport "$PORT_RANGE" -j ACCEPT 2>/dev/null
done

# single instance
if ! mkdir "$LOCK" 2>/dev/null; then
    OLD=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "${OLD:-}" ] && kill -0 "$OLD" 2>/dev/null; then
        echo "[xboard] another start is running"
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

if ps | grep -q "[/]tmp/xboard-node/xboard-node"; then
    echo "[xboard] already running"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    [ -s "$GZ" ] || { echo "[xboard] missing $GZ"; exit 1; }
    TMPBIN="$BIN.tmp.$$"
    gunzip -c "$GZ" > "$TMPBIN" || { rm -f "$TMPBIN"; exit 1; }
    chmod 755 "$TMPBIN" && mv -f "$TMPBIN" "$BIN" || { rm -f "$TMPBIN"; exit 1; }
fi

[ -s "$CFG_P" ] || { echo "[xboard] missing $CFG_P"; exit 1; }
cp -f "$CFG_P" "$CFG"

if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

nohup "$BIN" -c "$CFG" >>"$LOG" 2>&1 &
echo $! > "$PID"
sleep 6

if kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "[xboard] started (pid $(cat "$PID"))"
else
    echo "[xboard] failed to start"
    tail -n 20 "$LOG" 2>/dev/null
    exit 1
fi
STARTEOF

  sed -i "s#xboard-node.gz#xboard-node-$ARCH.gz#" "$START"
  if [ -n "$PORTS" ]; then
    sed -i "s#^PORT_RANGE=\"\"#PORT_RANGE=\"$PORTS\"#" "$START"
  fi
  chmod 755 "$START"
  log "wrote $START"

  # boot hook in /data
  if [ ! -f "$HOOK" ] || ! grep -q "KSXNode_ASUSWRT_BOOT" "$HOOK" 2>/dev/null; then
    if [ -s "$HOOK" ]; then
      BAK="$HOOK.bak.$(date +%Y%m%d%H%M%S)"
      cp -p "$HOOK" "$BAK" 2>/dev/null || true
      warn "existing $HOOK backed up to $BAK"
    fi
    cat > "$HOOK" <<'HOOKEOF'
#!/bin/sh
# KSXNode_ASUSWRT_BOOT
i=0
while [ ! -f /jffs/xboard-node/start.sh ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 1
done
if [ -x /jffs/xboard-node/start.sh ]; then
    /jffs/xboard-node/start.sh >> /tmp/xboard-node-boot.log 2>&1
fi
HOOKEOF
    chmod 755 "$HOOK"
    log "wrote boot hook $HOOK"
  else
    log "boot hook already present: $HOOK"
  fi

  # start now
  /bin/sh "$START" || true

  sleep 2
  if ps | grep -q "[/]tmp/xboard-node/xboard-node"; then
    log "KSXNode Node is running (Asuswrt /jffs mode)."
    log "Persistent: $PERSIST"
    log "Runtime:    $RUN"
    return 0
  fi
  warn "Service is not active. Recent logs:"
  tail -n 30 "$RUN/xboard-node.log" 2>/dev/null || true
  return 1
}

if [ "$SERVICE_MODE" = "asuswrt" ]; then
  install_asuswrt || exit 1
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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
