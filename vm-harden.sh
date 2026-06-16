#!/usr/bin/env bash
#
# vm-harden.sh (HOST) — idempotent lockdown of the disposable VM.
#
# Powers the VM off (graceful, then forced) and applies a hardened config:
#   * clipboard + drag-and-drop disabled
#   * ALL shared folders removed
#   * networking: nic1 DETACHED by default (no outbound), host-only nic2 for SSH
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

# --- Networking: detached nic1 (baseline) + host-only nic2 for SSH ---
# nic1 is the OPTIONAL internet adapter. Its BASELINE is detached (null) so the
# 'clean-base' snapshot captures a no-outbound posture: every run boots isolated
# and only `vm-cycle.sh --net` flips nic1 to NAT. See lib/config.sh.
set_nic1_mode "${NIC1_DETACHED_MODE}"
ok "nic1=${NIC1_DETACHED_MODE} (detached): baseline posture has NO outbound network."

# SSH no longer rides NAT, so drop any stale nic1 port-forwards (read, then act).
mapfile -t _portfwds < <(
  VBoxManage showvminfo "${VM_NAME}" --machinereadable \
    | sed -n 's/^Forwarding([0-9]*)="\([^,]*\),.*$/\1/p'
)
for _fwd in "${_portfwds[@]}"; do
  [ -n "${_fwd}" ] || continue
  log "Removing stale NAT port-forward '${_fwd}' (SSH now uses host-only nic2)"
  VBoxManage modifyvm "${VM_NAME}" --natpf1 delete "${_fwd}" 2>/dev/null || true
done

# nic2 is a PERMANENT host-only control link: host->guest reachable, but it
# carries no internet route, so SSH survives with nic1 detached. The flag name
# differs across VirtualBox versions, so try the new spelling then the old.
ensure_hostonly_if
VBoxManage modifyvm "${VM_NAME}" --nic2 hostonly --host-only-adapter2 "${HOSTONLY_IF}" 2>/dev/null \
  || VBoxManage modifyvm "${VM_NAME}" --nic2 hostonly --hostonlyadapter2 "${HOSTONLY_IF}"
ok "nic2=hostonly on ${HOSTONLY_IF}; guest SSH target ${HOSTONLY_GUEST_IP}:${GUEST_SSH_PORT}."

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

  3. Give nic2 (the host-only control link) a STATIC IP so the host can SSH in
     even while nic1 is detached. Find the 2nd interface name, then configure it:
         ip -o link show | awk -F': ' '{print \$2}'   # e.g. enp0s8

         # Create /etc/netplan/99-hostonly.yaml (match YOUR nic2 name), 0600:
         #   network:
         #     version: 2
         #     ethernets:
         #       enp0s8:
         #         dhcp4: no
         #         addresses: [${HOSTONLY_GUEST_IP}/24]
         sudo netplan apply

  4. Verify from the HOST that SSH answers over the host-only link:
         ssh -p ${SSH_PORT} ${RUNNER_USER}@${SSH_ADDR}

  5. Power the guest off cleanly, then capture the clean baseline:
         ./vm-cycle.sh --snapshot

After that, ./vm-cycle.sh (no args) drives each disposable run.
----------------------------------------------------------------------
EOF
