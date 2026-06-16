#!/usr/bin/env bash
#
# vm-harden.sh (HOST) — idempotent lockdown of the disposable VM.
#
# Powers the VM off (graceful, then forced) and applies a hardened config:
#   * clipboard + drag-and-drop disabled
#   * ALL shared folders removed
#   * NAT-only networking with a single host->guest SSH port-forward
#   * fixed RAM / CPU count
#   * audio + USB controllers disabled (attack-surface reduction)
#
# Safe to re-run: every change is declarative and reapplied each time.
#
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"

require_vboxmanage
require_vm_exists

log "Current VM state: $(vm_state)"
ensure_powered_off   # modifyvm requires the VM to be powered off

log "Applying hardened configuration to '${VM_NAME}'..."

# --- Host <-> guest data channels: off ---
VBoxManage modifyvm "${VM_NAME}" --clipboard-mode disabled
VBoxManage modifyvm "${VM_NAME}" --draganddrop disabled
ok "Clipboard + drag-and-drop disabled."

# --- Remove ALL shared folders (read state first, then act) ---
mapfile -t _shares < <(
  VBoxManage showvminfo "${VM_NAME}" --machinereadable \
    | sed -n 's/^SharedFolderNameMachineMapping[0-9]*="\(.*\)"$/\1/p'
)
if [ "${#_shares[@]}" -eq 0 ]; then
  ok "No shared folders present."
else
  for _sf in "${_shares[@]}"; do
    [ -n "${_sf}" ] || continue
    log "Removing shared folder: ${_sf}"
    VBoxManage sharedfolder remove "${VM_NAME}" --name "${_sf}" 2>/dev/null || true
  done
  ok "Shared folders removed."
fi

# --- Networking: NAT only + a single SSH port-forward (idempotent) ---
VBoxManage modifyvm "${VM_NAME}" --nic1 nat

# Clear ANY existing nic1 forward occupying the host SSH port, regardless of its
# rule name. Deleting only by SSH_RULE_NAME misses a forward added under a
# different name (e.g. a pre-existing uppercase 'SSH'), which then collides on
# the host port when we re-add. Read the current rules first, then act.
mapfile -t _portfwds < <(
  VBoxManage showvminfo "${VM_NAME}" --machinereadable \
    | sed -n 's/^Forwarding([0-9]*)="\(.*\)"$/\1/p' \
    | awk -F, -v port="${HOST_SSH_PORT}" -v ip="${HOST_SSH_ADDR}" \
        '$4 == port && ($3 == "" || $3 == ip) { print $1 }'
)
for _fwd in "${_portfwds[@]}"; do
  [ -n "${_fwd}" ] || continue
  log "Removing conflicting NAT forward '${_fwd}' (host port ${HOST_SSH_PORT})"
  VBoxManage modifyvm "${VM_NAME}" --natpf1 delete "${_fwd}" 2>/dev/null || true
done

VBoxManage modifyvm "${VM_NAME}" \
  --natpf1 "${SSH_RULE_NAME},tcp,${HOST_SSH_ADDR},${HOST_SSH_PORT},,${GUEST_SSH_PORT}"
ok "nic1=nat, forward ${HOST_SSH_ADDR}:${HOST_SSH_PORT} -> guest:${GUEST_SSH_PORT} (rule '${SSH_RULE_NAME}')."

# --- Resources ---
VBoxManage modifyvm "${VM_NAME}" --memory "${VM_MEMORY_MB}" --cpus "${VM_CPUS}"
ok "memory=${VM_MEMORY_MB}MB, cpus=${VM_CPUS}."

# --- Attack-surface reduction: audio + USB off (flag name varies by VBox ver) ---
VBoxManage modifyvm "${VM_NAME}" --audio-enabled off 2>/dev/null \
  || VBoxManage modifyvm "${VM_NAME}" --audio none 2>/dev/null \
  || warn "Could not disable audio (non-fatal)."
VBoxManage modifyvm "${VM_NAME}" --usb-ehci off 2>/dev/null || true
VBoxManage modifyvm "${VM_NAME}" --usb-xhci off 2>/dev/null || true
VBoxManage modifyvm "${VM_NAME}" --usb-ohci off 2>/dev/null || true
ok "Audio + USB controllers disabled."

ok "Hardening complete for '${VM_NAME}'."

cat >&2 <<EOF

----------------------------------------------------------------------
NEXT STEPS (one-time guest setup, then snapshot)
----------------------------------------------------------------------
The guest still needs an SSH server and an UNPRIVILEGED 'runner' user
before the snapshot. Do this once:

  1. Boot the VM with a console so you can log in:
         VBoxManage startvm "${VM_NAME}" --type gui
     (or --type separate / --type headless + the VirtualBox UI)

  2. Inside the guest, as your existing admin user, run:
         sudo apt-get update
         sudo apt-get install -y openssh-server
         sudo systemctl enable --now ssh

         # Create a NON-sudo user to run untrusted code as:
         sudo adduser --disabled-password --gecos "" ${RUNNER_USER}
         sudo passwd ${RUNNER_USER}        # set a password (or install a key)
         # IMPORTANT: do NOT add '${RUNNER_USER}' to the sudo/admin group.

         # (optional, recommended) install your host pubkey for key auth:
         #   sudo -u ${RUNNER_USER} mkdir -p /home/${RUNNER_USER}/.ssh
         #   ...append your id_*.pub to authorized_keys, chmod 600...

  3. Verify from the HOST that SSH answers:
         ssh -p ${HOST_SSH_PORT} ${RUNNER_USER}@${HOST_SSH_ADDR}

  4. Power the guest off cleanly, then capture the clean baseline:
         ./snapshot-base.sh

After that, ./vm-up.sh and ./vm-down.sh drive each disposable run.
----------------------------------------------------------------------
EOF
