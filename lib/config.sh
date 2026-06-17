#!/usr/bin/env bash
# lib/config.sh — shared configuration + helpers for repo-quarantine HOST scripts.
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

# --- Networking + SSH control channel --------------------------------------
# The control channel rides nic1 in NAT mode with a single host->guest SSH
# port-forward. NAT needs NO guest-side network config (Ubuntu DHCPs the NAT
# NIC automatically), which makes the host->guest path robust across reboots
# and snapshot restores. NAT also gives the guest full OUTBOUND internet — that
# is an accepted, documented limitation, NOT a defended boundary (see README).
HOST_SSH_ADDR="${HOST_SSH_ADDR:-127.0.0.1}"   # host side of the port-forward
HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"         # host side of the port-forward
GUEST_SSH_PORT="${GUEST_SSH_PORT:-22}"         # sshd inside the guest
SSH_RULE_NAME="${SSH_RULE_NAME:-ssh}"          # name of the NAT port-forward
# Private key the host authenticates with (its .pub goes in runner's
# authorized_keys). A VM-dedicated key keeps this isolated from your other keys.
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/vm_runner}"

VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_CPUS="${VM_CPUS:-2}"

SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-180}"   # margin for an occasional slow first boot (snapd reseed)
ACPI_WAIT_SECONDS="${ACPI_WAIT_SECONDS:-60}"

# Common SSH options: host keys are intentionally NOT persisted because the
# guest identity changes on every snapshot restore, so verification is moot.
SSH_COMMON_OPTS=(
  -p "${HOST_SSH_PORT}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

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
    || die "Snapshot '${SNAPSHOT_NAME}' not found for '${VM_NAME}'. Run ./vm-cycle.sh --snapshot first."
}

# Prints nic1's current attachment: nat, null, hostonly, bridged, none, ...
# Read this BEFORE changing the network posture so we never blindly modify.
nic1_type() {
  VBoxManage showvminfo "${VM_NAME}" --machinereadable 2>/dev/null \
    | sed -n 's/^nic1="\(.*\)"$/\1/p'
}

# Lists the rule names of nic1 NAT port-forwards whose host port == HOST_SSH_PORT
# (regardless of rule name), so a caller can clear a conflicting forward before
# adding ours. Reads state first; never modifies.
nic1_ssh_forwards() {
  VBoxManage showvminfo "${VM_NAME}" --machinereadable 2>/dev/null \
    | sed -n 's/^Forwarding([0-9]*)="\(.*\)"$/\1/p' \
    | awk -F, -v port="${HOST_SSH_PORT}" -v ip="${HOST_SSH_ADDR}" \
        '$4 == port && ($3 == "" || $3 == ip) { print $1 }'
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
  # The ssh call is EXPECTED to fail (exit 255): PreferredAuthentications=none
  # offers no auth, so sshd rejects us. Reachability is judged by the rejection
  # banner, NOT by ssh's exit status. We therefore CAPTURE the output first and
  # grep the variable, rather than piping 'ssh | grep': callers run under
  # 'set -o pipefail', which would make the pipeline inherit ssh's 255 and mask
  # grep's match — a false "unreachable" even while sshd is answering.
  local out
  out="$(ssh "${SSH_COMMON_OPTS[@]}" \
      -o ConnectTimeout=4 \
      -o BatchMode=yes \
      -o PreferredAuthentications=none \
      "${RUNNER_USER}@${HOST_SSH_ADDR}" true 2>&1)" || true
  grep -qiE 'permission denied|authentication|publickey|password' <<<"${out}"
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
