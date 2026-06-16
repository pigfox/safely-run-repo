# safely-run-repo

A tiny host-side toolkit for cloning and running **any untrusted repository**
inside a disposable VirtualBox VM, then throwing the VM away. Language-agnostic:
web apps (Laravel/PHP, Node) and crypto/Web3 repos (Rust/Foundry/Hardhat/Solana/
Python) alike.

The model is simple:

> **The VM is the security boundary.** Clone executes nothing; install executes
> everything. So run the install and the app inside a throwaway VM, as a non-sudo
> user, and restore a clean snapshot after every run. No scanners, no allowlists
> — isolation plus rollback is the protection.

---

## Hard caveats — read these first

- **The VM isolates the host FILESYSTEM, not the NETWORK.** Networking is NAT, so
  the guest still has full **outbound** internet. Anything you log into, paste,
  or type inside the VM can be exfiltrated over the wire. Rollback wipes the disk;
  it cannot un-send a network request.
- **Never bring real secrets in.** No real SSH keys, API tokens, passwords, or
  credentials inside the VM — assume anything you put there is stolen.
- **Crypto/Web3: testnet only.** No real private keys, seed phrases, keystores,
  or mainnet wallets. The headline danger is key theft over the network, and a
  snapshot rollback **cannot undo a key that already left the VM.** Use throwaway
  testnet keys exclusively.
- **Run untrusted code as `runner`, never root.** Everything runs as the non-sudo
  `runner` user. If a repo asks for `sudo`, that is a finding, not an instruction.
- **Keep the escape channels closed.** Clipboard, drag-and-drop, and shared
  folders stay **off** — they are VM-escape / data-leak channels. `vm-harden.sh`
  disables them; don't re-enable them.
- **A VM is strong isolation, not absolute.** Hypervisor-escape bugs exist. That
  is exactly why the channels above stay shut and why you **restore `clean-base`
  after every run** — a compromise then has nothing to grab and nowhere to persist.

---

## What's in the box

| File | Runs on | Purpose |
| --- | --- | --- |
| `lib/config.sh` | host | Shared config (VM name, port, snapshot, runner) + guard helpers. Sourced by both scripts. |
| `vm-harden.sh` | host | One-time: idempotently lock the VM down — no clipboard/drag-drop/shares, NAT + a single SSH forward, fixed RAM/CPU, audio/USB off. |
| `vm-cycle.sh` | host | Every run: restore `clean-base`, boot headless, wait for SSH, drop you into the VM as `runner`; on exit/Ctrl-C, power off and roll back. `--snapshot` captures the baseline. |

Both host scripts read VM state **before** any state-changing `VBoxManage` call,
print actionable errors, and centralize every magic literal in `lib/config.sh`
(override any value via the environment, e.g. `VM_NAME=other ./vm-cycle.sh`).

Defaults: `VM_NAME=ubuntu-vm`, SSH `127.0.0.1:2222 → guest:22`, snapshot
`clean-base`, user `runner`, `4096 MB` RAM, `2` CPUs.

---

## One-time setup

```bash
# 1. Harden the existing 'ubuntu-vm' (powers it off first; idempotent).
./vm-harden.sh

# 2. Follow the printed NEXT STEPS: boot the VM once, install openssh-server,
#    and create the NON-sudo 'runner' user. (vm-harden.sh prints exact commands.)

# 3. Capture the clean baseline every run restores to.
./vm-cycle.sh --snapshot          # add --force to replace an existing one
```

After that, `vm-cycle.sh` (no args) drives every disposable run.

---

## The workflow — vet one repo

```bash
./vm-cycle.sh                     # HOST: restore clean-base, boot, ssh in as runner

# --- inside the VM ---
git clone https://github.com/some/unknown-repo.git    # cloning executes nothing
cd unknown-repo
# install + run the challenge work here, as 'runner', never sudo
exit                              # leave the guest shell

# back on the HOST: the teardown trap fires automatically —
#   acpi power-off -> forced poweroff if needed -> restore 'clean-base'.
# Everything the repo did is gone.
```

Ctrl-C instead of `exit` triggers the same teardown. The only time the VM is
**not** rolled back is if SSH never comes up: it's left running so you can boot
it with `--type gui` and inspect what's wrong with the `clean-base` snapshot.
