# repo-quarantine

A tiny host-side toolkit for cloning and running an **untrusted repository**
inside a disposable VirtualBox VM, then throwing the VM away. Language-agnostic:
web apps (Laravel/PHP, Node) and crypto/Web3 repos (Rust/Foundry/Hardhat/Solana/
Python) alike.

> **Read the threat model below before you trust this with anything.**
> Quarantine means isolation, not safety. This tool gives you *one specific*
> protection — a disposable host-filesystem boundary — and nothing more. Knowing
> exactly where that boundary stops is the whole point.

---

## Threat model — what this protects against, and what it does NOT

**The one thing it guarantees:** it isolates the **host filesystem**. Untrusted
code runs inside a throwaway VM as a non-sudo user, and a clean snapshot is
restored after every run. Whatever the repo writes, installs, or breaks lives
and dies inside the VM. That disposable boundary is the entire guarantee.

Everything below is **out of scope** — do not assume the tool covers it:

- **It does NOT contain outbound network abuse when you use `--net`.** With the
  network enabled, the guest has full outbound internet: it can exfiltrate
  anything it can read, call home to a C2, or mine. **Snapshot rollback wipes
  the disk; it cannot un-send a packet.** This is exactly why the **default mode
  is network-OFF** (see [Network modes](#network-modes-default-off-vs---net)).
- **It does NOT defend against VM-escape bugs.** Hypervisor escapes are rare but
  real. That is precisely why clipboard, drag-and-drop, and shared folders stay
  **disabled** (`vm-harden.sh` turns them off) — fewer escape/leak channels — and
  why you restore `clean-base` after every run so a compromise has nothing to
  persist into.
- **It does NOT make a repo "safe."** A clean run proves *nothing* about the
  code — only that this run didn't escape the box. The VM is the boundary, not a
  verdict. Never carry "it ran fine in the VM" over to running it on your host.
- **Crypto/Web3: the dominant risk is key/seed theft over the wire.** A snapshot
  rollback cannot undo a key that already left the VM. **Never put real private
  keys, seed phrases, keystores, or mainnet wallets inside the VM. Testnet and
  throwaway keys only.** The same goes for any real secret — SSH keys, API
  tokens, passwords: assume anything you bring in is stolen.
- **Untrusted code runs as the non-sudo `runner` user, never root.** If a repo
  demands `sudo`, that is a finding to investigate, not an instruction to follow.

In short: **the VM is the security boundary, and it is a *filesystem* boundary.**
Network containment is your responsibility (use the default off mode); secret
hygiene is your responsibility (bring none); judging the code is your
responsibility (the tool never does).

---

## Network modes (default OFF vs `--net`)

SSH to the guest rides a dedicated **host-only adapter** (`nic2`) that has no
route to the internet, so the host can always reach the guest — independent of
whether the guest has outbound. That lets the internet adapter (`nic1`) default
to fully detached without losing your shell.

| Mode | Command | nic1 (internet) | SSH (host-only nic2) | Use when |
| --- | --- | --- | --- | --- |
| **Default — isolated** | `./vm-cycle.sh` | **detached** (no outbound) | works | The default. Inspect, read, and run code that should not need the network. Nothing can phone home or exfiltrate. |
| **Networked** | `./vm-cycle.sh --net` | **NAT** (full outbound) | works | Only when the repo genuinely must pull dependencies (`npm install`, `cargo build`, `pip`, `git clone` of submodules). `--net` prints a loud warning: outbound is live and rollback cannot un-send anything. |

Teardown always restores `nic1` to the detached baseline, so the **next** run
starts isolated no matter how the last one ran.

> **Rule of thumb:** start without `--net`. Add it only for the install step that
> actually needs it, and remember that everything the repo did over the wire
> during that window is already irreversible.

---

## What's in the box

| File | Runs on | Purpose |
| --- | --- | --- |
| `lib/config.sh` | host | Shared config (VM name, snapshot, runner, network adapters) + guard helpers. Sourced by both scripts. |
| `vm-harden.sh` | host | One-time: idempotently lock the VM down — no clipboard/drag-drop/shares, `nic1` detached baseline, host-only `nic2` for SSH, fixed RAM/CPU, audio/USB off. |
| `vm-cycle.sh` | host | Every run: restore `clean-base`, set the network posture, boot headless, wait for SSH, drop you into the VM as `runner`; on exit/Ctrl-C, power off and roll back. `--net` enables outbound; `--snapshot` captures the baseline. |

Both host scripts read VM state **before** any state-changing `VBoxManage` call,
print actionable errors, and centralize every magic literal in `lib/config.sh`
(override any value via the environment, e.g. `VM_NAME=other ./vm-cycle.sh`).

Defaults: `VM_NAME=ubuntu-vm`, host-only SSH `192.168.56.10:22` via `vboxnet0`
(host `192.168.56.1`), snapshot `clean-base`, user `runner`, `4096 MB` RAM,
`2` CPUs.

---

## One-time setup

```bash
# 1. Harden the existing 'ubuntu-vm' (powers it off first; idempotent).
#    Sets nic1 detached, creates/attaches the host-only nic2.
./vm-harden.sh

# 2. Follow the printed NEXT STEPS: boot the VM once, install openssh-server,
#    create the NON-sudo 'runner' user, and give nic2 a STATIC IP so the host
#    can SSH in while nic1 is detached. (vm-harden.sh prints exact commands.)

# 3. Capture the clean baseline every run restores to.
./vm-cycle.sh --snapshot          # add --force to replace an existing one
```

After that, `vm-cycle.sh` (no args) drives every disposable run.

---

## The workflow — vet one repo

```bash
./vm-cycle.sh                     # HOST: restore clean-base, boot ISOLATED, ssh in
#   ./vm-cycle.sh --net           # ...or boot WITH outbound, if deps must be pulled

# --- inside the VM ---
git clone https://github.com/some/unknown-repo.git    # cloning executes nothing
cd unknown-repo
# install + run the work here, as 'runner', never sudo
exit                              # leave the guest shell

# back on the HOST: the teardown trap fires automatically —
#   acpi power-off -> forced poweroff if needed -> restore 'clean-base'
#   -> reset nic1 to the detached baseline.
# Everything the repo did to the disk is gone. (Anything it sent over the
# network with --net is NOT — see the threat model.)
```

Ctrl-C instead of `exit` triggers the same teardown. The only time the VM is
**not** rolled back is if SSH never comes up: it's left running so you can boot
it with `--type gui` and inspect what's wrong with the `clean-base` snapshot.
