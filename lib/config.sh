#!/usr/bin/env bash
# lib/config.sh — shared configuration + helpers for safely-run-repo HOST scripts.
#
# This file is SOURCED by vm-harden.sh and vm-cycle.sh. It is not meant to be
# executed directly. All host-side "magic literals" live in the config block
# below; every value can be overridden from the environment.

# ---------------------------------------------------------------------------
# Config block — single source of truth for every magic literal.
# ---------------------------------------------------------------------------
VM_NAME="${VM_NAME:-ubuntu-vm}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-clean-base}"
RUNNER_USER="${RUNNER_USER:-runner}"

HOST_SSH_ADDR="${HOST_SSH_ADDR:-127.0.0.1}"
HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"
GUEST_SSH_PORT="${GUEST_SSH_PORT:-22}"
SSH_RULE_NAME="${SSH_RULE_NAME:-ssh}"

VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_CPUS="${VM_CPUS:-2}"

SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-120}"
ACPI_WAIT_SECONDS="${ACPI_WAIT_SECONDS:-60}"

# ---------------------------------------------------------------------------
# Output helpers (everything goes to stderr so stdout stays scriptable).
# ---------------------------------------------------------------------------
if [ -t 2 ]; then
  _C_BLUE=$'\033[1;34m'; _C_GREEN=$'\033[1;32m'
  _C_YELLOW=$'\033[1;33m'; _C_RED=$'\033[1;31m'; _C_RST=$'\033[0m'
else
  _C_BLUE=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_RST=''
fi

log()  { printf '%s[*]%s %s\n' "$_C_BLUE"   "$_C_RST" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$_C_GREEN"  "$_C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$_C_YELLOW" "$_C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$_C_RED"    "$_C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisite + read-only state helpers. NEVER ASSUME, VERIFY: callers must
# use these to read VM state before any state-changing VBoxManage call.
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 \
    || die "Required command '$cmd' not found.${hint:+ $hint}"
}

require_vboxmanage() {
  require_cmd VBoxManage "Install VirtualBox on the host."
}

vm_exists() {
  VBoxManage list vms 2>/dev/null | grep -q "\"${VM_NAME}\""
}

require_vm_exists() {
  vm_exists || die "VM '${VM_NAME}' not registered with VirtualBox. Create it first."
}

# Prints the raw VMState value: running, poweroff, saved, aborted, paused, ...
vm_state() {
  VBoxManage showvminfo "${VM_NAME}" --machinereadable 2>/dev/null \
    | sed -n 's/^VMState="\(.*\)"$/\1/p'
}

vm_is_running() {
  case "$(vm_state)" in
    running|starting|stopping|paused|stuck|live) return 0 ;;
    *) return 1 ;;
  esac
}

snapshot_exists() {
  VBoxManage snapshot "${VM_NAME}" list --machinereadable 2>/dev/null \
    | grep -qE "^SnapshotName[^=]*=\"${SNAPSHOT_NAME}\"$"
}

require_snapshot() {
  snapshot_exists \
    || die "Snapshot '${SNAPSHOT_NAME}' not found for '${VM_NAME}'. Run snapshot-base.sh first."
}

# ---------------------------------------------------------------------------
# Power control. Tries a graceful ACPI shutdown, falls back to a hard poweroff.
# ---------------------------------------------------------------------------
power_off_acpi() {
  log "Sending ACPI power button to '${VM_NAME}' (graceful shutdown)..."
  VBoxManage controlvm "${VM_NAME}" acpipowerbutton >/dev/null 2>&1 || true
  local deadline=$(( SECONDS + ACPI_WAIT_SECONDS ))
  while (( SECONDS < deadline )); do
    vm_is_running || { ok "VM powered off."; return 0; }
    sleep 2
  done
  return 1
}

power_off_hard() {
  warn "Graceful shutdown timed out; forcing power off of '${VM_NAME}'..."
  VBoxManage controlvm "${VM_NAME}" poweroff >/dev/null 2>&1 || true
  sleep 2
}

ensure_powered_off() {
  vm_is_running || return 0
  power_off_acpi && return 0
  power_off_hard
  vm_is_running && die "Unable to power off '${VM_NAME}'. Resolve manually in VirtualBox."
  ok "VM powered off (forced)."
  return 0
}

# ---------------------------------------------------------------------------
# Wait until the guest SSH daemon answers through the NAT port-forward.
# Uses PreferredAuthentications=none so ANY auth-rejection banner proves the
# daemon is up, regardless of whether keys or passwords are configured.
# ---------------------------------------------------------------------------
ssh_reachable() {
  ssh -p "${HOST_SSH_PORT}" \
      -o ConnectTimeout=4 \
      -o BatchMode=yes \
      -o PreferredAuthentications=none \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${RUNNER_USER}@${HOST_SSH_ADDR}" true 2>&1 \
    | grep -qiE 'permission denied|authentication|publickey|password'
}

wait_for_ssh() {
  require_cmd ssh "Install the openssh-client package on the host."
  local deadline=$(( SECONDS + SSH_WAIT_SECONDS ))
  while (( SECONDS < deadline )); do
    ssh_reachable && return 0
    sleep 2
  done
  return 1
}
