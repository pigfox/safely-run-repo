#!/usr/bin/env bash
#
# vm-cycle.sh (HOST) — one disposable run of the VM.
#
# Restores the 'clean-base' snapshot, boots headless, waits for the guest SSH
# daemon, then hands you an interactive shell as the unprivileged runner. When
# that shell exits (or you Ctrl-C), a teardown trap powers the VM off and
# restores 'clean-base' again, discarding everything the session did.
#
# Networking is OFF by default: nic1 boots DETACHED, so untrusted code has NO
# outbound (no exfil, C2, or mining). SSH still works because it rides a
# separate host-only adapter (nic2). Pass --net to enable outbound NAT for the
# runs that genuinely must pull dependencies — see the warning it prints.
#
# Run an untrusted repo like this:
#     ./vm-cycle.sh              # isolated: no outbound network
#     ./vm-cycle.sh --net        # outbound NAT enabled (deps) -- see warning
#     # inside the guest: git clone <unknown-repo>, do the work, then `exit`
#     # -> the host wipes the VM back to the clean baseline automatically
#
#   --net        Boot WITH outbound NAT on nic1 (default is detached/no net).
#   --snapshot   Don't run a cycle: power the VM off and capture the
#                'clean-base' baseline that every run restores to. Use once,
#                after vm-harden.sh + the manual guest setup (sshd + runner).
#   --force      With --snapshot: replace an existing 'clean-base' snapshot.
#
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"

SNAPSHOT_MODE=0
FORCE=0
NET_MODE=0
usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "${arg}" in
    --net|--network) NET_MODE=1 ;;
    --snapshot) SNAPSHOT_MODE=1 ;;
    --force)    FORCE=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "Unknown argument: ${arg} (try --help)" ;;
  esac
done

require_vboxmanage
require_vm_exists

# ---------------------------------------------------------------------------
# --snapshot: capture the clean baseline (folds in the old snapshot-base.sh).
# ---------------------------------------------------------------------------
if [ "${SNAPSHOT_MODE}" -eq 1 ]; then
  if snapshot_exists && [ "${FORCE}" -eq 0 ]; then
    die "Snapshot '${SNAPSHOT_NAME}' already exists. Re-run with --snapshot --force to replace it."
  fi

  log "Current VM state: $(vm_state)"
  ensure_powered_off   # taking a snapshot of a clean baseline requires power-off

  # Bake the detached baseline into the snapshot so every restore starts with NO
  # outbound, regardless of nic1's state when --snapshot was invoked.
  set_nic1_mode "${NIC1_DETACHED_MODE}"

  if snapshot_exists && [ "${FORCE}" -eq 1 ]; then
    warn "Deleting existing snapshot '${SNAPSHOT_NAME}' (--force)..."
    VBoxManage snapshot "${VM_NAME}" delete "${SNAPSHOT_NAME}"
  fi

  log "Taking snapshot '${SNAPSHOT_NAME}'..."
  VBoxManage snapshot "${VM_NAME}" take "${SNAPSHOT_NAME}" \
    --description "Clean baseline for repo-quarantine: hardened, openssh-server, non-sudo ${RUNNER_USER}."
  ok "Snapshot '${SNAPSHOT_NAME}' captured. Run ./vm-cycle.sh to start a disposable run."
  exit 0
fi

# ---------------------------------------------------------------------------
# Default: one disposable run.
# ---------------------------------------------------------------------------
require_cmd ssh "Install the openssh-client package on the host."
require_snapshot   # fail clearly if 'clean-base' has not been captured yet

_TORN_DOWN=0
teardown() {
  [ "${_TORN_DOWN}" -eq 1 ] && return 0
  _TORN_DOWN=1
  trap - EXIT INT TERM
  echo >&2
  log "Tearing down '${VM_NAME}' (acpi -> poweroff) and restoring '${SNAPSHOT_NAME}'..."
  ensure_powered_off   # graceful ACPI, wait, then forced poweroff if still up
  if ! snapshot_exists; then
    warn "Snapshot '${SNAPSHOT_NAME}' missing; VM powered off but NOT wiped."
  elif VBoxManage snapshot "${VM_NAME}" restore "${SNAPSHOT_NAME}" >/dev/null; then
    ok "Run wiped. '${VM_NAME}' restored to '${SNAPSHOT_NAME}' and powered off."
  else
    warn "Snapshot restore failed; inspect '${VM_NAME}' manually."
  fi
  # Force nic1 back to the detached baseline so the NEXT run starts isolated no
  # matter how this one ran. set_nic1_mode verifies state before any modifyvm.
  set_nic1_mode "${NIC1_DETACHED_MODE}" \
    || warn "Could not reset nic1 to '${NIC1_DETACHED_MODE}'; check before next run."
}

log "Current VM state: $(vm_state)"
ensure_powered_off   # restoring a snapshot requires the VM to be off

log "Restoring snapshot '${SNAPSHOT_NAME}' (discarding any prior run)..."
VBoxManage snapshot "${VM_NAME}" restore "${SNAPSHOT_NAME}"
ok "Snapshot restored."

# Arm teardown for everything past this point: any exit, error, or Ctrl-C now
# powers the VM off and rolls back to the clean baseline.
trap teardown EXIT INT TERM

# Set the network posture BEFORE boot (VM is off; set_nic1_mode reads state
# first). SSH always rides the host-only nic2, so it works in either mode.
if [ "${NET_MODE}" -eq 1 ]; then
  warn "NETWORK IS LIVE (--net): nic1=${NIC1_NET_MODE}. The guest now has full"
  warn "OUTBOUND internet — anything inside can phone home, exfiltrate data,"
  warn "mine, or pull a second-stage payload. Snapshot rollback wipes the disk"
  warn "but CANNOT UN-SEND a packet. Use only when the repo must fetch deps."
  set_nic1_mode "${NIC1_NET_MODE}"
else
  set_nic1_mode "${NIC1_DETACHED_MODE}"
  ok "Network OFF: nic1=${NIC1_DETACHED_MODE} (no outbound). Pass --net to enable."
fi

log "Starting '${VM_NAME}' headless..."
VBoxManage startvm "${VM_NAME}" --type headless

log "Waiting up to ${SSH_WAIT_SECONDS}s for SSH on ${SSH_ADDR}:${SSH_PORT} (host-only)..."
if ! wait_for_ssh; then
  # Leave the VM running and DON'T roll back, so the failure can be inspected.
  trap - EXIT INT TERM
  err "SSH never became reachable. The guest may lack openssh-server, or the"
  err "host-only nic2 / static IP (${HOSTONLY_GUEST_IP}) / '${RUNNER_USER}' user"
  err "is misconfigured in '${SNAPSHOT_NAME}'. Inspect the guest console with:"
  err "    VBoxManage controlvm ${VM_NAME} poweroff   # then:"
  err "    VBoxManage startvm ${VM_NAME} --type gui"
  die "Aborting; VM left running for inspection (not rolled back)."
fi
ok "SSH reachable. Opening interactive shell as '${RUNNER_USER}'."
echo >&2

# Run ssh as a CHILD (not exec) so the teardown trap fires when it returns.
# A non-zero ssh exit (incl. Ctrl-C in the session) must not skip cleanup.
# Host keys are intentionally not persisted: the guest identity changes on
# every snapshot restore, so verification here is moot.
ssh -p "${SSH_PORT}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${RUNNER_USER}@${SSH_ADDR}" || true

# Falling off the end triggers the EXIT trap -> teardown.
