#!/usr/bin/env bash
# QEMU harness for testing this playbook on a Pop!_OS 24.04 VM.
#
#   scripts/vm-test.sh fetch      download the Pop!_OS 24.04 (Intel/AMD) ISO into vm/
#   scripts/vm-test.sh install    boot the ISO against vm/base.qcow2; install Pop by hand
#   scripts/vm-test.sh run        boot a throwaway overlay on top of base.qcow2
#   scripts/vm-test.sh reset      discard the overlay so the next `run` starts clean
#   scripts/vm-test.sh sync       rsync this repo into ~/ansible-popos-workstation-base in the VM
#   scripts/vm-test.sh provision  sync, then run ./run.sh in the VM over SSH
#
# Env: ISO, VM_DIR (./vm), MEM_MB (8192), CPUS (4), DISPLAY_OPT (default),
#      SSH_PORT (2222), VM_USER ($USER), ACCEL (auto: kvm/hvf/tcg),
#      OVMF_CODE / OVMF_VARS_TEMPLATE (auto-detected), DRY_RUN=1 (print qemu cmd).
#
# base.qcow2 stays pristine after the manual install; every `run` boots an
# overlay (run.qcow2) so a test can be thrown away with `reset`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VM_DIR="${VM_DIR:-${HERE}/vm}"
ISO="${ISO:-${VM_DIR}/pop-os-24.04.iso}"
BASE="${VM_DIR}/base.qcow2"
BASE_VARS="${VM_DIR}/base_VARS.fd"
OVERLAY="${VM_DIR}/run.qcow2"
RUN_VARS="${VM_DIR}/run_VARS.fd"
DISK_SIZE="${DISK_SIZE:-60G}"
MEM_MB="${MEM_MB:-8192}"
CPUS="${CPUS:-4}"
DISPLAY_OPT="${DISPLAY_OPT:-default}"
SSH_PORT="${SSH_PORT:-2222}"
VM_USER="${VM_USER:-${USER}}"
DRY_RUN="${DRY_RUN:-0}"
REMOTE_DIR="ansible-popos-workstation-base"
SSH_OPTS=(-p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

detect_accel() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo kvm ;;
    Darwin-x86_64) echo hvf ;;
    *) echo tcg ;;
  esac
}
ACCEL="${ACCEL:-$(detect_accel)}"

find_first() {
  local f
  for f in "$@"; do
    if [ -f "${f}" ]; then echo "${f}"; return 0; fi
  done
  return 1
}

firmware() {
  OVMF_CODE="${OVMF_CODE:-$(find_first \
    /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd || true)}"
  OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-$(find_first \
    /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /opt/homebrew/share/qemu/edk2-i386-vars.fd /usr/local/share/qemu/edk2-i386-vars.fd || true)}"
  if [ "${DRY_RUN}" = 1 ]; then
    OVMF_CODE="${OVMF_CODE:-OVMF_CODE.fd}"
    OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-OVMF_VARS.fd}"
    return
  fi
  if [ -z "${OVMF_CODE}" ] || [ -z "${OVMF_VARS_TEMPLATE}" ]; then
    echo "OVMF UEFI firmware not found. Linux: apt install ovmf. macOS: brew install qemu." >&2
    echo "Or set OVMF_CODE and OVMF_VARS_TEMPLATE." >&2
    exit 1
  fi
  command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found" >&2; exit 1; }
  if [ "${ACCEL}" = tcg ]; then
    echo "WARNING: no hardware acceleration for x86_64 on this host (ACCEL=tcg)." >&2
    echo "         COSMIC will be very slow. Prefer a Linux x86_64 host with KVM." >&2
  fi
}

# boot <disk> <vars> [extra qemu args...]
boot() {
  local disk="$1" vars="$2"
  shift 2
  local cpu=host
  [ "${ACCEL}" = tcg ] && cpu=max
  local cmd=(qemu-system-x86_64
    -machine "type=q35,accel=${ACCEL}" -cpu "${cpu}"
    -m "${MEM_MB}" -smp "${CPUS}"
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${vars}"
    -drive "file=${disk},format=qcow2,if=none,id=disk0"
    -device "virtio-blk-pci,drive=disk0,bootindex=1"
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
    -device virtio-vga
    -display "${DISPLAY_OPT}"
    "$@")
  if [ "${DRY_RUN}" = 1 ]; then
    printf '%q ' "${cmd[@]}"
    echo
    return
  fi
  exec "${cmd[@]}"
}

cmd_fetch() {
  mkdir -p "${VM_DIR}"
  local meta url sha
  meta="$(curl -fsSL https://api.pop-os.org/builds/24.04/intel)"
  url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])' <<<"${meta}")"
  sha="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sha_sum"])' <<<"${meta}")"
  echo "==> ${url}"
  curl -fL --continue-at - -o "${ISO}" "${url}"
  echo "${sha}  ${ISO}" | shasum -a 256 -c -
}

cmd_install() {
  firmware
  if [ "${DRY_RUN}" != 1 ]; then
    [ -f "${ISO}" ] || { echo "No ISO at ${ISO}; run: scripts/vm-test.sh fetch" >&2; exit 1; }
    mkdir -p "${VM_DIR}"
    [ -f "${BASE}" ] || qemu-img create -f qcow2 "${BASE}" "${DISK_SIZE}" >/dev/null
    [ -f "${BASE_VARS}" ] || cp "${OVMF_VARS_TEMPLATE}" "${BASE_VARS}"
  fi
  boot "${BASE}" "${BASE_VARS}" \
    -drive "file=${ISO},format=raw,if=none,id=cd0,media=cdrom" \
    -device ide-cd,drive=cd0,bootindex=2
}

cmd_run() {
  firmware
  if [ "${DRY_RUN}" != 1 ]; then
    [ -f "${BASE}" ] || { echo "No base disk; run: scripts/vm-test.sh install" >&2; exit 1; }
    if [ ! -f "${OVERLAY}" ]; then
      qemu-img create -f qcow2 -b "${BASE}" -F qcow2 "${OVERLAY}" >/dev/null
      cp "${BASE_VARS}" "${RUN_VARS}"
    fi
  fi
  boot "${OVERLAY}" "${RUN_VARS}"
}

cmd_reset() {
  rm -f "${OVERLAY}" "${RUN_VARS}"
  echo "==> overlay discarded; next 'run' starts from base.qcow2"
}

cmd_sync() {
  rsync -a --delete --exclude vm/ --exclude .ansible/ --exclude .cache/ \
    -e "ssh ${SSH_OPTS[*]}" "${HERE}/" "${VM_USER}@localhost:${REMOTE_DIR}/"
}

cmd_provision() {
  cmd_sync
  # shellcheck disable=SC2029  # REMOTE_DIR is meant to expand locally
  ssh -t "${SSH_OPTS[@]}" "${VM_USER}@localhost" \
    "cd ${REMOTE_DIR} && { [ -f vars/vars.yml ] || cp vars/vars.example.yml vars/vars.yml; } && ./run.sh"
}

case "${1:-}" in
  fetch) cmd_fetch ;;
  install) cmd_install ;;
  run) cmd_run ;;
  reset) cmd_reset ;;
  sync) cmd_sync ;;
  provision) cmd_provision ;;
  *) usage ;;
esac
