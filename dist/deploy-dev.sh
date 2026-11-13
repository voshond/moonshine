#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 ]]; then
  BOLD='\033[1m' DIM='\033[2m' CYAN='\033[36m' GREEN='\033[32m' RED='\033[31m' RESET='\033[0m'
else
  BOLD='' DIM='' CYAN='' GREEN='' RED='' RESET=''
fi

info() { echo -e "${BOLD}${CYAN}::${RESET} ${BOLD}$*${RESET}"; }
step() { echo -e "  ${DIM}->${RESET} $*"; }
ok()   { echo -e " ${BOLD}${GREEN}✓${RESET} $*"; }
die()  { echo -e " ${BOLD}${RED}✗${RESET} $*" >&2; exit 1; }

print_help() {
  cat <<EOF
deploy-dev.sh — build this checkout and deploy it to a remote host over ssh

Usage: dist/deploy-dev.sh [options]

Builds moonshine and ferriscope's WSI layer here, copies them to HOST, installs
them under PREFIX and points moonshine@USER.service at them with a systemd
drop-in. Packaged files (/usr/bin/moonshine and friends) are left untouched, so
--rollback returns the host to its packaged moonshine.

Options:
  --host HOST        ssh host to deploy to (default: arch, or \$MOONSHINE_DEPLOY_HOST)
  --user USER        service instance moonshine@USER (default: the ssh login user)
  --prefix PREFIX    install directory on the host (default: /opt/moonshine-dev)
  --ferriscope PATH  build moonshine and the WSI layer against a local ferriscope
                     checkout instead of the revision in Cargo.lock
  --debug            build the debug profile
  --skip-build       deploy what the last build left in target/
  --rollback         remove the dev deployment and restart the packaged moonshine
  -h, --help         show this message

Sudo on the host asks for its password in this terminal.
EOF
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${MOONSHINE_DEPLOY_HOST:-arch}"
SERVICE_USER=""
PREFIX="/opt/moonshine-dev"
FERRISCOPE=""
PROFILE="release"
SKIP_BUILD=false
MODE="deploy"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) SERVICE_USER="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --ferriscope) FERRISCOPE="$(realpath "$2")"; shift 2 ;;
    --debug) PROFILE="debug"; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --rollback) MODE="rollback"; shift ;;
    --apply) MODE="apply"; shift ;;
    --apply-rollback) MODE="apply-rollback"; shift ;;
    -h | --help) print_help ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$PREFIX" == /opt/* || "$PREFIX" == /usr/local/* ]] || die "--prefix must live under /opt or /usr/local, got: ${PREFIX}"

UNIT="moonshine@${SERVICE_USER}.service"
DROPIN_DIR="/etc/systemd/system/moonshine@.service.d"
DROPIN="${DROPIN_DIR}/10-dev.conf"
LAYER_JSON="VkLayer_FERRISCOPE_wsi.x86_64.json"
SYSTEM_LAYER="/etc/vulkan/implicit_layer.d/${LAYER_JSON}"

apply_deploy() {
  local src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ $EUID -eq 0 ]] || die "--apply runs as root on the host"

  info "Stopping ${UNIT}"
  systemctl stop "$UNIT" 2>/dev/null || true
  pkill -u "$SERVICE_USER" -x moonshine 2>/dev/null || true

  info "Installing into ${PREFIX}"
  if [[ -f "${PREFIX}/bin/moonshine" ]]; then
    step "keeping the previous build as ${PREFIX}/bin/moonshine.prev"
    cp -f "${PREFIX}/bin/moonshine" "${PREFIX}/bin/moonshine.prev"
  fi
  install -Dm755 "${src}/bin/moonshine" "${PREFIX}/bin/moonshine"
  install -Dm755 "${src}/start-moonshine.sh" "${PREFIX}/start-moonshine.sh"
  install -Dm755 "${src}/lib/ferriscope/libferriscope_wsi.so" "${PREFIX}/lib/ferriscope/libferriscope_wsi.so"
  install -Dm644 "${src}/share/vulkan/implicit_layer.d/${LAYER_JSON}" "$SYSTEM_LAYER"
  install -Dm644 "${src}/10-dev.conf" "$DROPIN"
  step "WSI layer manifest: ${SYSTEM_LAYER}"
  step "systemd drop-in:    ${DROPIN}"

  systemctl daemon-reload
  systemd-sysusers 2>/dev/null || true
  modprobe uinput 2>/dev/null || true
  modprobe uhid 2>/dev/null || true

  info "Starting ${UNIT}"
  systemctl start "$UNIT"
  sleep 2
  systemctl --no-pager --lines=15 status "$UNIT" || die "${UNIT} is not running"
  ok "$("${PREFIX}/bin/moonshine" --version 2>/dev/null || echo moonshine) running from ${PREFIX}"
}

apply_rollback() {
  [[ $EUID -eq 0 ]] || die "--apply-rollback runs as root on the host"

  info "Removing the dev deployment"
  systemctl stop "$UNIT" 2>/dev/null || true
  rm -f "$DROPIN" "$SYSTEM_LAYER"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  rm -rf "$PREFIX"
  systemctl daemon-reload

  info "Starting the packaged ${UNIT}"
  systemctl start "$UNIT"
  sleep 2
  systemctl --no-pager --lines=15 status "$UNIT" || die "${UNIT} is not running"
  ok "rolled back to the packaged moonshine"
}

build() {
  local cargo_args=(build --bin moonshine)
  local lock_backup=""

  [[ "$PROFILE" == "release" ]] && cargo_args+=(--release)

  if [[ -n "$FERRISCOPE" ]]; then
    [[ -f "${FERRISCOPE}/Cargo.toml" ]] || die "no ferriscope checkout at ${FERRISCOPE}"
    step "using ferriscope from ${FERRISCOPE}"
    lock_backup="$(mktemp)"
    cp "${ROOT}/Cargo.lock" "$lock_backup"
    trap 'cp "'"$lock_backup"'" "'"${ROOT}/Cargo.lock"'"; rm -f "'"$lock_backup"'"' EXIT
    cargo_args+=(--config "patch.\"https://github.com/hgaiser/ferriscope\".ferriscope.path=\"${FERRISCOPE}\"")
  else
    cargo_args+=(--locked)
  fi

  info "Building moonshine (${PROFILE})"
  (cd "$ROOT" && cargo "${cargo_args[@]}")
}

stage() {
  local stage_dir="$1"
  local binary="${ROOT}/target/${PROFILE}/moonshine"

  [[ -x "$binary" ]] || die "no build at ${binary}; run without --skip-build"

  info "Staging into ${stage_dir#"${ROOT}/"}"
  rm -rf "$stage_dir"
  mkdir -p "${stage_dir}/bin"

  step "building ferriscope WSI layer"
  DESTDIR="${stage_dir}/wsi" FERRISCOPE_SRC="${FERRISCOPE}" "${ROOT}/dist/install-wsi.sh" --prefix "$PREFIX"
  cp -r "${stage_dir}/wsi${PREFIX}/." "$stage_dir"
  rm -rf "${stage_dir}/wsi"

  cp "$binary" "${stage_dir}/bin/moonshine"
  sed "s|/usr/bin/moonshine|${PREFIX}/bin/moonshine|g" "${ROOT}/dist/start-moonshine.sh" > "${stage_dir}/start-moonshine.sh"
  printf '[Service]\nExecStart=\nExecStart=%s/start-moonshine.sh /home/%%i/.config/moonshine/config.toml\n' "$PREFIX" > "${stage_dir}/10-dev.conf"
  cp "${BASH_SOURCE[0]}" "${stage_dir}/deploy-dev.sh"
  chmod 755 "${stage_dir}/deploy-dev.sh" "${stage_dir}/start-moonshine.sh"
}

resolve_service_user() {
  [[ -n "$SERVICE_USER" ]] && return
  SERVICE_USER="$(ssh "$HOST" id -un)" || die "cannot reach ${HOST} over ssh"
  UNIT="moonshine@${SERVICE_USER}.service"
}

deploy() {
  local stage_dir="${ROOT}/target/dev-deploy"
  local remote_dir

  [[ $EUID -ne 0 ]] || die "run as your normal user; sudo is only used on the host"
  resolve_service_user

  [[ "$SKIP_BUILD" == "true" ]] || build
  stage "$stage_dir"

  remote_dir="/tmp/moonshine-dev-deploy-${SERVICE_USER}"
  info "Copying to ${HOST}:${remote_dir}"
  rsync -az --delete "${stage_dir}/" "${HOST}:${remote_dir}/"

  info "Installing on ${HOST} (sudo)"
  ssh -t "$HOST" "sudo bash '${remote_dir}/deploy-dev.sh' --apply --user '${SERVICE_USER}' --prefix '${PREFIX}'"
  ok "deployed $(git -C "$ROOT" describe --tags --always --dirty) to ${HOST}"
  echo -e "  ${DIM}logs${RESET}  ${BOLD}ssh ${HOST} journalctl -fu ${UNIT}${RESET}"
}

rollback() {
  local remote_dir="/tmp/moonshine-dev-rollback"

  resolve_service_user
  info "Rolling back ${HOST}"
  ssh "$HOST" mkdir -p "$remote_dir"
  rsync -a "${BASH_SOURCE[0]}" "${HOST}:${remote_dir}/deploy-dev.sh"
  ssh -t "$HOST" "sudo bash '${remote_dir}/deploy-dev.sh' --apply-rollback --user '${SERVICE_USER}' --prefix '${PREFIX}'"
}

case "$MODE" in
  apply) apply_deploy ;;
  apply-rollback) apply_rollback ;;
  rollback) rollback ;;
  deploy) deploy ;;
esac
