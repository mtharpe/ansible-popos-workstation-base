# Changelog

## Unreleased (Pop!_OS port)
- Fork of ansible-ubuntu-workstation-base for Pop!_OS 24.04 with COSMIC
- Replace `roles/gnome` with `roles/cosmic` (RON config writer, panel/dock/tiling layout, custom shortcuts, dark mode, Colloid icons, portal screenshots + Satty 0.20.1)
- Add Twingate (signed apt repo), Cider (flatpak) and electron-apps from the Fedora playbook
- Add Pop!_OS preflight check and a junk-app purge that refuses to remove pop-desktop/COSMIC
- Remove WSL playbook, Multipass, snap launcher shadowing and GNOME extensions
- Add `scripts/vm-test.sh` QEMU harness, `molecule/cosmic` scenario, `make lint`
- Fix Molecule scenarios so they converge (templates symlink, handlers, test vars) and make the 1Password repo file idempotent

## Unreleased
- Convert role layout to mirror `ansible-fedora-workstation-base` (top-level `templates/`, `handlers/`, `meta/`, `molecule/`, `Makefile`)
- Translate Fedora-specific tooling to Ubuntu equivalents: `dnf`→`apt`, `yum_repository`/`rpm_key`→`apt_repository`/`apt_key`, `wheel`→`sudo`, `sshd`→`ssh`, `firewalld`→`ufw`
- Pin Molecule image to `ubuntu:24.04`
- Introduce `ubuntu_version` variable in `vars/vars.yml` for easier future bumps
- Drop WSL playbook/role/wsl.sh, Vagrantfile, scaffolding `template.yml`, and unused `configuration` role
