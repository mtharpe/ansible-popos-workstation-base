# Pop!_OS Workstation Base

Ansible playbook that sets up a **Pop!_OS 24.04 LTS (COSMIC)** laptop for
development and daily use. Sibling of
[ansible-ubuntu-workstation-base](https://github.com/mtharpe/ansible-ubuntu-workstation-base)
and [ansible-fedora-workstation-base](https://github.com/mtharpe/ansible-fedora-workstation-base):
same tools, apps and shell setup, with the GNOME pieces translated to COSMIC.

> **Status:** the COSMIC config keys in `vars/vars.example.yml` are
> provisional until they are captured from a real Pop!_OS 24.04 install —
> see `docs/cosmic-keys.md`. Everything else has been tested in containers.

## What this does

- **Common packages** — developer tooling, fonts, codecs, HashiCorp tools, 1Password (`roles/common`)
- **Third-party apps** — Chrome, VS Code, Slack, Zoom, Twingate, Cider, Claude Code/Desktop, kubectl, electron web apps and more, each behind an `install_*` flag (`roles/third-party`)
- **COSMIC settings** — dark mode, 12-hour clock, touchpad/mouse, window buttons, workspaces, top panel without dock, tiling off, custom shortcuts (`roles/cosmic`)
- **Theming** — Colloid icons; dark mode that also reaches GTK2/GTK3, Qt and Electron apps
- **Screenshots** — Shift+Alt+3 full screen to clipboard; Shift+Alt+4 area grab annotated in Satty
- **Hardening** — fail2ban, ufw desktop firewall, optional sshd hardening
- **Safety** — refuses to run on anything but Pop!_OS 24.04, and refuses a junk-app purge that would take `pop-desktop`/COSMIC with it

## Quick start

1. Install Pop!_OS 24.04 (tick "Encrypt drive" in the installer), log in once.
2. Clone and run:

   ```sh
   git clone https://github.com/mtharpe/ansible-popos-workstation-base.git
   cd ansible-popos-workstation-base
   cp vars/vars.example.yml vars/vars.yml   # edit toggles as needed
   ./run.sh
   ```

3. Log out and back in (environment variables and some COSMIC applets only reload at login).
4. If Twingate is enabled: `twingate setup`.

`run.sh` installs Ansible via pipx, adds a temporary passwordless-sudo drop-in, runs the playbook (up to `RUN_RETRIES`, default 3, attempts for flaky mirrors), and removes the drop-in however it exits. It needs ansible-core 2.19 or newer (pipx installs the latest).

## Customising COSMIC

COSMIC stores one setting per file under `~/.config/cosmic/<component>/v<N>/<key>`.
`cosmic_settings` in `vars/vars.yml` lists the files this playbook writes;
`docs/cosmic-keys.md` records where each value came from. To add a setting:
`touch /tmp/marker`, change it in COSMIC Settings, find the file that changed
with `find ~/.config/cosmic -newer /tmp/marker -type f`, and copy its
component, version, key and contents into `cosmic_settings`.

Re-running the playbook resets only the listed keys. **Custom shortcuts are
the exception: `cosmic_custom_keybindings` replaces the whole custom-shortcuts
file**, so add shortcuts there rather than in COSMIC Settings.

## Not on COSMIC

Behaviour from the Ubuntu/Fedora GNOME setup that has no COSMIC equivalent:

- Fixed count of 5 workspaces (COSMIC workspaces are dynamic)
- Alt+Tab switching applications rather than windows
- Weather and world-clock locations
- GNOME Shell extensions: just-perfection, auto-move-windows, power-profile-switcher, auto-select-headset, silent-cycle-current-app, chrome-pwa-grouper
- GNOME font overrides (COSMIC's defaults are kept)
- Multipass (snap-only; Pop!_OS has no snapd)
- auto-cpufreq (Pop's system76-power already manages CPU power; the task refuses to install alongside it)

Pending the key capture in `docs/cosmic-keys.md` (added if COSMIC has a key for them):

- Battery percentage in the panel
- Automatic timezone
- Suppressing desktop notifications from terminal apps

## Feature flags

See `vars/vars.example.yml` — every `install_*` flag is documented inline.
Satty is pinned to 0.20.1: newer release binaries need glibc 2.43 and Pop!_OS
24.04 has 2.39.

## Testing

- `make lint` — yamllint, ansible-lint, playbook syntax check, shellcheck, and the local tests in `tests/`: leftovers, VM-script dry run, `run.sh` retry cap, cosmic config writers under `--tags` and with an empty shortcut list, and a static check that `pipefail` shell tasks run under bash
- `make test-docker` — Molecule converge + idempotence + verify of `common` and `third-party` on an Ubuntu 24.04 (amd64) container, including the junk-purge guard and the Twingate repo
- `make test-cosmic` — Molecule for the `cosmic` role: config files and ownership, layout, shortcuts, theming, Colloid icons, screenshot helpers and Satty
- `ANSIBLE_ROLES_PATH=roles ansible-playbook tests/preflight.yml` — must fail on a non-Pop host
- Full run on a Pop!_OS VM with `scripts/vm-test.sh` (`fetch`, `install`, `run`, `provision`, `reset`). Needs QEMU; fast on a Linux x86_64 host with KVM, very slow under emulation on Apple Silicon.

## Linting and CI

CircleCI runs ansible-lint, yamllint, `ansible-playbook --syntax-check`, Molecule syntax for the default scenario, and shellcheck.

## License

MIT
