# HANDOFF — safely-run-repo

Working notes for the next session. Delete or trim once the workflow is in daily use.

Last updated: 2026-06-15 · branch `main` · HEAD `0c53bc4`

---

## Status: toolkit built, verified, committed. VM setup NOT yet done.

All 7 deliverables exist, are executable, `set -euo pipefail`, and shellcheck-clean
(verified with `pipx run shellcheck-py -x`). `scan.sh` was smoke-tested against a
fixture and caught all planted threats; exit codes 0/1/2 confirmed.

**Nothing has been run that mutates the VM.** `ubuntu-vm` is still: powered off,
`nic1=nat`, `cpus=1`, no snapshot. The hardening + snapshot are the operator's
one-time setup, left for you to trigger.

---

## File map

| File | Role |
|------|------|
| `lib/config.sh` | All magic literals + read-before-write VBox guard helpers. Sourced by the `vm-*` scripts. NOT sourced by `scan.sh` (kept standalone so it can be scp'd into the VM alone). |
| `vm-harden.sh` | Idempotent VM lockdown. Mutates directly (confirmed choice). Prints guest setup steps. |
| `snapshot-base.sh` | Take `clean-base`. `--force` to replace. |
| `vm-up.sh` | Restore `clean-base` → boot headless → wait SSH → `exec ssh` as `runner`. |
| `vm-down.sh` | Poweroff + restore `clean-base` (default wipes run). `--destroy` = unregister+delete (prompts for VM-name confirmation). |
| `scan.sh` | Standalone static scanner. Arg = TARGET (default `$PWD`). Report `/tmp/malware-scan-<ts>.log`. |
| `run-order.md` | Safe sequence: clone → scan → read hooks → disarmed install → re-scan → run → wipe. |
| `README.md` | Overview + quickstart + hard caveats. |
| `rules/` | Optional YARA `*.yar` drop-in (currently empty → step self-skips). |

---

## Confirmed design decisions (do not re-litigate)

- **vm-down restores clean-base by default** (wipes the run). User confirmed.
- **vm-harden mutates the VM directly** (no dry-run default). User confirmed.
- **`--destroy`** requires typing the VM name to proceed.
- Committed straight to `main` (fresh personal repo, user asked for files "in the repo").

---

## Host environment facts (verified this session)

- VBoxManage `7.2.6`. VM `ubuntu-vm` exists, poweroff, `nic1=nat`, memory 4096, **cpus=1** (harden sets 2).
- `semgrep` is at `~/.local/bin/semgrep` (NOT `/snap/bin` as the brief assumed) — scripts resolve via `command -v`, so fine.
- Present: `clamscan`, `trivy`, `git`, `file`, `python3`, `ssh`.
- **Missing**: `yara` (YARA step self-skips), `clamdscan` (falls back to `clamscan`), `sshpass` (unused; key/interactive auth).
- `shellcheck` not installed natively — lint via `pipx run shellcheck-py -x <file>`.

---

## NEXT STEPS (operator, in order)

```bash
# 1. Harden (powers VM off first; idempotent). Prints guest setup commands.
./vm-harden.sh

# 2. Boot once, inside guest: install openssh-server + create NON-sudo runner.
#    (exact commands are printed by vm-harden.sh)

# 3. Capture baseline.
./snapshot-base.sh

# 4. First real run — Laravel hiring-challenge (see run-order.md):
./vm-up.sh
#   in VM: git clone https://github.com/wwwidr/hiring-challenge.git
#          ~/scan.sh .   → read report + composer.json by hand
#          composer install --no-scripts --no-plugins
#          ~/scan.sh .   → re-scan
#          run it
exit
./vm-down.sh
```

`scan.sh` is not baked into the snapshot yet. Until it is, copy it in each run:
`scp -P 2222 scan.sh runner@127.0.0.1:/home/runner/` — or bake it into the guest
home before taking `clean-base` so it's always present.

---

## Known gaps / possible follow-ups

- Install `yara` + author `rules/*.yar` (e.g. Contagious-Interview / known web3 stealer patterns) to light up that scan step.
- Consider baking `scan.sh` into the `clean-base` snapshot so no scp is needed per run.
- `scan.sh` Semgrep/Trivy steps need network for rules/DB; inside a NAT VM that's fine, but note they self-skip with a clear message if offline.
- No automated test harness committed — the fixture smoke test was ad-hoc this session. Could add a `tests/` fixture + expected-flags assertion if this grows.
- `vm-up.sh` disables SSH host-key checking on purpose (guest identity changes every snapshot restore). Documented inline; don't "fix" it.
