#!/usr/bin/env bash
# =============================================================================
#  llamastack uninstaller
#  Usage: sudo ./uninstall.sh [options]
# =============================================================================
set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
KEEP_MODELS=0
YES=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-models) KEEP_MODELS=1; shift ;;
    -y|--yes)      YES=1; shift ;;
    -h|--help)
      cat <<HELP
Usage: sudo ./uninstall.sh [options]

  --keep-models   Remove binaries/config but preserve downloaded model weights
  -y, --yes       Non-interactive
  -h, --help      Show this help
HELP
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' NC='\033[0m'
ok()   { echo -e "${G}  ✓${NC}  $*"; }
warn() { echo -e "${Y}  !${NC}  $*"; }
info() { echo -e "${C}  →${NC}  $*"; }
die()  { echo -e "${R}  ✗${NC}  $*" >&2; exit 1; }
hdr()  { echo -e "\n${B}$*${NC}"; echo "$(printf '─%.0s' {1..56})"; }

# ── Privilege ─────────────────────────────────────────────────────────────────
OS=$(uname -s)
[[ $OS == Linux && $EUID -ne 0 ]] && die "Run as root on Linux: sudo $0"
[[ $EUID -ne 0 ]] && SUDO=sudo || SUDO=""

# ── Locate config ─────────────────────────────────────────────────────────────
CONF="${LLAMASTACK_CONF:-/opt/llamastack/config/llamastack.conf}"
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
  PREFIX="${PREFIX:-/opt/llamastack}"
  info "Config loaded: $CONF"
else
  PREFIX="/opt/llamastack"
  warn "Config not found — using default prefix: $PREFIX"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}llamastack uninstaller${NC}"
echo ""
echo "  Prefix      : ${PREFIX}"
echo "  Keep models : $([ $KEEP_MODELS -eq 1 ] && echo yes || echo no)"
echo ""
if [[ $YES -eq 0 ]]; then
  read -rp "  Proceed? [y/N] " ans
  [[ ${ans:-N} =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

# ── Stop and remove services ───────────────────────────────────────────────────
hdr "Removing services"
case "$OS" in
  Linux)
    for SVC in gen embed; do
      UNIT="llamastack-${SVC}"
      systemctl stop    "$UNIT" 2>/dev/null && ok "Stopped  $UNIT"  || true
      systemctl disable "$UNIT" 2>/dev/null && ok "Disabled $UNIT"  || true
      if [[ -f "/etc/systemd/system/${UNIT}.service" ]]; then
        rm -f "/etc/systemd/system/${UNIT}.service"
        ok "Removed  /etc/systemd/system/${UNIT}.service"
      fi
    done
    systemctl daemon-reload && ok "systemd reloaded"
    if id llamastack &>/dev/null 2>&1; then
      userdel llamastack 2>/dev/null && ok "Removed service user: llamastack" || \
        warn "Could not remove user llamastack (check for running processes)"
    fi
    ;;
  Darwin)
    for SVC in gen embed; do
      PLIST="/Library/LaunchDaemons/com.llamastack.${SVC}.plist"
      LABEL="com.llamastack.${SVC}"
      $SUDO launchctl stop   "$LABEL" 2>/dev/null && ok "Stopped  $LABEL" || true
      $SUDO launchctl unload "$PLIST" 2>/dev/null && ok "Unloaded $PLIST" || true
      [[ -f "$PLIST" ]] && { $SUDO rm -f "$PLIST"; ok "Removed  $PLIST"; }
    done
    ;;
esac

# ── Remove CLI symlinks ────────────────────────────────────────────────────────
hdr "Removing CLI"
for link in /usr/local/bin/llamastack /usr/bin/llamastack; do
  [[ -L "$link" || -f "$link" ]] && { $SUDO rm -f "$link"; ok "Removed $link"; }
done

# ── Clean up git safe.directory ───────────────────────────────────────────────
git config --global --unset-all safe.directory "${PREFIX}/src/llama.cpp" 2>/dev/null || true
git config --system  --unset-all safe.directory "${PREFIX}/src/llama.cpp" 2>/dev/null || true

# ── Remove files ──────────────────────────────────────────────────────────────
hdr "Removing files"

if [[ $KEEP_MODELS -eq 1 ]]; then
  for subdir in bin config src logs run docs; do
    [[ -d "${PREFIX}/${subdir}" ]] && { $SUDO rm -rf "${PREFIX:?}/${subdir}"; ok "Removed ${PREFIX}/${subdir}"; }
  done
  $SUDO find "${PREFIX}" -maxdepth 1 -type f -delete 2>/dev/null || true
  warn "Model weights preserved: ${PREFIX}/models/"
  warn "Remove manually when done:  rm -rf ${PREFIX}/models"
else
  if [[ $YES -eq 0 ]]; then
    read -rp "  Delete downloaded models in ${PREFIX}/models/ too? [y/N] " del_m
  else
    del_m=y
  fi
  if [[ ${del_m:-N} =~ ^[Yy] ]]; then
    $SUDO rm -rf "${PREFIX:?}"
    ok "Removed ${PREFIX} (including models)"
  else
    $SUDO rm -rf \
      "${PREFIX:?}/bin"    \
      "${PREFIX:?}/config" \
      "${PREFIX:?}/src"    \
      "${PREFIX:?}/logs"   \
      "${PREFIX:?}/run"    \
      "${PREFIX:?}/docs"   2>/dev/null || true
    ok "Removed binaries and config"
    warn "Models preserved: ${PREFIX}/models/"
  fi
fi

echo ""
echo -e "${G}  llamastack uninstalled.${NC}"
echo ""
