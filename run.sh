#!/usr/bin/env bash

set -euo pipefail

[[ "${DEBUG:-0}" -eq 1 ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR}"

RUN_CONFIG_DEFAULT="$REPO_ROOT/.run.local.env"
RUN_CONFIG="${RUN_CONFIG:-$RUN_CONFIG_DEFAULT}"

load_config() {
    if [ -f "$RUN_CONFIG" ]; then
        echo "[INFO] Loading config from $RUN_CONFIG"
        set -a
        . "$RUN_CONFIG"
        set +a
    fi
}

normalize() {
    case "$1" in
        /*)  printf "%s\n" "$1" ;;
        *)   printf "%s/%s\n" "$REPO_ROOT" "$1" ;;
    esac
}

log()  { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [flags]

Flags:
  --image repo:tag           Image to deploy (default: ${IMAGE:-your-registry/your-image:latest})
  --skip-bootstrap           Skip bootstrap step
  --only {bootstrap|nftables|caddy|bouncer|deploy}
                             Execute only one step and exit
  --skip-bouncer 
  --build-from-archive       Download HTTPS tarball and build image
  --repo-url URL             Repository URL (default: ${REPO_URL:-https://github.com/owner/repo.git})
  --ref REF                  Branch/tag/commit to use (default: ${REPO_REF:-main})
  --dockerfile PATH          Dockerfile path within the repo (default: ${DOCKERFILE_PATH:-Dockerfile})
  --push                     Perform docker push after building

Examples:
  ./run.sh --skip-bootstrap
  IMAGE=johndoe/app-reflex:v2 ./run.sh
  ./run.sh --build-from-archive --ref main --image johndoe/app-reflex:latest
  ./run.sh --only deploy --build-from-archive --push
EOF
}

SKIP_BOOTSTRAP=0
ONLY_STEP=""
RUN_BOUNCER=1
BUILD_FROM_ARCHIVE="${BUILD_FROM_ARCHIVE:-0}"
PUSH_IMAGE="${PUSH_IMAGE:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2;;
        --skip-bootstrap) SKIP_BOOTSTRAP=1; shift;;
        --only) ONLY_STEP="$2"; shift 2;;
        --skip-bouncer) RUN_BOUNCER=0; shift;;
        --build-from-archive) BUILD_FROM_ARCHIVE=1; shift;;
        --repo-url) REPO_URL="$2"; shift 2;;
        --ref) REPO_REF="$2"; shift 2;;
        --dockerfile) DOCKERFILE_PATH="$2"; shift 2;;
        --push) PUSH_IMAGE=1; shift;;
        -h|--help) usage; exit 0;;
        *) fail "Unknown flag: $1 (use -h)";;
    esac
done

load_config

IMAGE="${IMAGE:-your-registry/your-image:latest}"
DOMAIN="${DOMAIN:-example.com}"
SCRIPTS_DIR="${SCRIPTS_DIR:-infra/scripts}"
MODULES_DIR="${MODULES_DIR:-infra/modules}"
CONFIG_DIR="${CONFIG_DIR:-infra/config}"
CADDYFILE_PATH="${CADDYFILE_PATH:-${CONFIG_DIR}/caddy/Caddyfile}"
CADDY_UNIT_PATH="${CADDY_UNIT_PATH:-${CONFIG_DIR}/systemd/caddy.service}"
REPO_URL="${REPO_URL:-https://github.com/owner/repo.git}"
REPO_REF="${REPO_REF:-main}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile}"

SCRIPTS_DIR="$(normalize "$SCRIPTS_DIR")"
MODULES_DIR="$(normalize "$MODULES_DIR")"
CONFIG_DIR="$(normalize "$CONFIG_DIR")"
CADDYFILE_PATH="$(normalize "$CADDYFILE_PATH")"
CADDY_UNIT_PATH="$(normalize "$CADDY_UNIT_PATH")"

source "${MODULES_DIR}/bootstrap_ec2.sh"
source "${MODULES_DIR}/update_caddy.sh"
source "${MODULES_DIR}/deploy_container.sh"
source "${MODULES_DIR}/backup_caddy.sh"

[[ -f "${MODULES_DIR}/bootstrap_ec2.sh" ]]    || fail "${MODULES_DIR}/bootstrap_ec2.sh does not exist"
[[ -f "${MODULES_DIR}/update_caddy.sh" ]]     || fail "${MODULES_DIR}/update_caddy.sh does not exist"
[[ -f "${MODULES_DIR}/deploy_container.sh" ]] || fail "${MODULES_DIR}/deploy_container.sh does not exist"
[[ -f "${SCRIPTS_DIR}/nftables.sh" ]]         || fail "${SCRIPTS_DIR}/nftables.sh does not exist"
[[ -f "${SCRIPTS_DIR}/firewall_bouncer.sh" ]] || fail "${SCRIPTS_DIR}/firewall_bouncer.sh does not exist"

if [[ "${SKIP_BOOTSTRAP}" -eq 1 ]] || [[ -n "${ONLY_STEP}" && "${ONLY_STEP}" != "bootstrap" ]]; then
    [[ -f "${CADDYFILE_PATH}" ]]  || fail "Does not exist in ${CADDYFILE_PATH}"
    [[ -f "${CADDY_UNIT_PATH}" ]] || fail "Does not exist in ${CADDY_UNIT_PATH}"
fi

chmod +x "${SCRIPTS_DIR}/"*.sh || true
chmod +x "${MODULES_DIR}/"*.sh || true

export CADDYFILE_PATH CADDY_UNIT_PATH

do_bootstrap() {
    log "Bootstrap EC2 (Docker, Caddy bin, usuario, unit)"
    if ! sudo -n true 2>/dev/null; then
        warn "This script attempts to use sudo without a password. If it prompts for a password, please enter it."
    fi
    update_system
    setup_docker
    install_caddy
    setup_caddy_user
    setup_logging
    setup_caddy_service
    setup_caddyfile
    
    backup_caddyfile || warn "Could not create backup of the initial Caddyfile"

    configure_network
    start_caddy

    warn "If this is the first time your user was added to the 'docker' group, log out and log back in."
}

do_nftables() {
    log "Hardening host with nftables (only 443 TCP/UDP)"
    ALLOW_SSH="${ALLOW_SSH:-0}" "${SCRIPTS_DIR}/nftables.sh"
}

do_caddy() {
    log "Install/Update Caddyfile and reload service"
    backup_caddyfile || warn "Could not create backup, continuing..."
    source "${MODULES_DIR}/update_caddy.sh"
    update_caddy_config "${CADDYFILE_PATH}" || fail "Error configuring Caddy"
}

do_bouncer() {
    log "Install/Configure CrowdSec + nftables firewall-bouncer"
    HOOK_FORWARD="${HOOK_FORWARD:-0}" "${SCRIPTS_DIR}/firewall_bouncer.sh"
}

do_fetch_archive_and_build() {
    [[ -n "${REPO_URL}" ]] || fail "REPO_URL vacío"
    [[ -n "${REPO_REF}" ]] || fail "REPO_REF vacío"

    if ! sudo docker info >/dev/null 2>&1; then
        fail "Docker not accessible. Please run bootstrap first with: ./run.sh --only bootstrap"
    fi

    local owner repo
    owner="$(printf "%s" "${REPO_URL}" | sed -E 's#https?://github.com/##; s#\.git$##' | cut -d/ -f1)"
    repo="$(printf "%s" "${REPO_URL}" | sed -E 's#https?://github.com/##; s#\.git$##' | cut -d/ -f2-)"

    log "Downloading public tarball: ${owner}/${repo}@${REPO_REF}"
    TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
    command -v curl >/dev/null || fail "Falta 'curl'"
    command -v tar  >/dev/null || fail "Falta 'tar'"

    curl -fL -o "${TMPDIR}/src.tgz" "https://codeload.github.com/${owner}/${repo}/tar.gz/${REPO_REF}"
    tar -xzf "${TMPDIR}/src.tgz" -C "${TMPDIR}"
    SRC_DIR="$(find "${TMPDIR}" -maxdepth 1 -type d -name "${owner}-${repo}-*" | head -n1)" || true
    [[ -d "${SRC_DIR}" ]] || fail "No decompressed tarball folder found."

    log "Building image ${IMAGE} using Dockerfile: ${DOCKERFILE_PATH}"
    [[ -f "${SRC_DIR}/${DOCKERFILE_PATH}" ]] || fail "${DOCKERFILE_PATH} was not found in the downloaded repository."

    sudo docker build --pull -f "${SRC_DIR}/${DOCKERFILE_PATH}" -t "${IMAGE}" "${SRC_DIR}"
    [[ "${PUSH_IMAGE}" -eq 1 ]] && sudo docker push "${IMAGE}"
    log "Image built: ${IMAGE}"
}

do_deploy() {
    log "Deploying app container → ${IMAGE}"
    
    load_config
    run_container "${IMAGE}" "my-app-container" 3000 8000
    wait_for_frontend || fail "Frontend did not respond."
    show_container_status
    
    log "Deploy completed successfully."
}

run_smoke_tests() {
    log "Quick smoke tests"
    set +e
    curl -I "https://${DOMAIN}" | sed -n '1,10p'
    curl -sS "https://${DOMAIN}" | head -n 5
    curl -I "https://www.${DOMAIN}" | sed -n '1,10p'
    set -e
}

case "${ONLY_STEP}" in
    "")       ;;
    bootstrap) do_bootstrap; exit 0;;
    nftables)  do_nftables; exit 0;;
    caddy)    do_caddy; exit 0;;
    bouncer)  do_bouncer; exit 0;;
    deploy)   [[ "${BUILD_FROM_ARCHIVE}" -eq 1 ]] && do_fetch_archive_and_build; do_deploy; exit 0;;
    *)        fail "--only must be bootstrap|nftables|caddy|bouncer|deploy" ;;
esac

if [[ "${SKIP_BOOTSTRAP}" -eq 0 ]]; then
    do_bootstrap
else
    log "Skipping bootstrap (--skip-bootstrap)"
fi

do_nftables
do_caddy

if [[ "${RUN_BOUNCER}" -eq 1 ]]; then
    do_bouncer
else
    log "Skipping bouncer (--skip-bouncer)"
fi

if [[ "${BUILD_FROM_ARCHIVE}" -eq 1 ]]; then
    do_fetch_archive_and_build
fi

do_deploy
run_smoke_tests

log "OK. Deployment complete."