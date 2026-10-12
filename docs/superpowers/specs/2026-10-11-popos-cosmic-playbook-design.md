# Pop!_OS 24.04 + COSMIC workstation playbook — design

Date: 2026-10-11
Status: approved in brainstorming, pending written-spec review

## Goal

Configure a laptop running Pop!_OS 24.04 LTS (COSMIC desktop) to the same
opinionated state as the existing `ansible-ubuntu-workstation-base` and
`ansible-fedora-workstation-base` playbooks: same CLI toolset, same
third-party apps, same shell setup, dark theme, same keyboard shortcuts —
translated to COSMIC where GNOME-specific mechanisms don't apply.

Usage: install Pop!_OS 24.04 normally (disk encryption via the installer
checkbox), log in, `git clone` this repo, `./run.sh`, log out and back in.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | Playbook only. No unattended ISO builder (Pop's installer has no Subiquity autoinstall); possible follow-up project. |
| Repo | New repo `ansible-popos-workstation-base`, created as a clone of `ansible-ubuntu-workstation-base` with history preserved. |
| Feature set | Ubuntu playbook as the base, plus the Fedora-only extras: Twingate, Cider, electron-apps, Colloid icons, Satty, terminal notification blocking, Qt/Electron dark-mode env, cursor-size fallback. |
| Desktop layout | Top panel kept, COSMIC dock disabled, auto-tiling off. Each is a vars toggle. |
| Verification | Pop!_OS 24.04 QEMU VM; COSMIC config keys captured from the real system, not guessed from docs. |

## Facts about the target that drive the design

- Pop!_OS 24.04 is built on Ubuntu 24.04 (noble) and uses apt.
  `ansible_facts['distribution_release']` is `noble`, so codename-keyed
  third-party apt repos (HashiCorp, Docker, …) resolve unchanged.
  `ansible_facts['distribution']` is `Pop!_OS`, not `Ubuntu` — any task
  that branches on distribution name must account for this.
- No snapd. Flatpak + Flathub ship preconfigured.
- COSMIC settings are **not** dconf. Each setting is one file:
  `~/.config/cosmic/<component-id>/v<N>/<key>` containing a RON value.
  System defaults live under `/usr/share/cosmic/`; a user file overrides.
- COSMIC has no extension system (GNOME Shell extensions do not run).
- Login screen is cosmic-greeter; power management is `system76-power`.

## Architecture

```
ansible-popos-workstation-base/
  setup_workstation.yml     roles: common → third-party → cosmic
  run.sh                    pipx ansible bootstrap + retry loop (unchanged)
  vars/vars.example.yml     defaults; vars/vars.yml is the gitignored copy
  roles/common/             from Ubuntu, minus snap handling; + preflight assertion
  roles/third-party/        from Ubuntu + twingate, cider, electron-apps
  roles/cosmic/             replaces roles/gnome
    tasks/main.yml
    tasks/settings.yml       generic writer for cosmic_settings
    tasks/layout.yml         panel/dock/tiling toggles
    tasks/keybindings.yml    custom shortcuts from cosmic_custom_keybindings
    tasks/theme.yml          dark mode, Colloid icons, GTK/Qt/Electron dark env, cursor size
    tasks/screenshots.yml    wl-copy helper scripts + Satty
    tasks/notifications.yml  terminal-app notification blocking (only if COSMIC supports it)
    files/                   screenshot helpers, colloid-icons/ extras (from Fedora)
  scripts/vm-test.sh         QEMU harness for the Pop VM
  molecule/                  Ubuntu 24.04 container scenario
```

### roles/common changes vs Ubuntu

- Add a preflight task (first in `main.yml`): assert
  `ansible_facts['distribution'] == 'Pop!_OS'` and major version `24`.
  Skippable via `popos_skip_preflight: true` so Molecule can run on an
  Ubuntu container.
- Remove snap-specific code: the Firefox/Thunderbird `NoDisplay` shadow
  `.desktop` files (Pop ships Firefox as a deb; the apt purge covers it).
- Junk-app removal list: revise to Pop's actual preinstalled apps (captured
  from the VM); drop GNOME app names that aren't present.
- `gnome-tweaks`, `gnome-extensions-app`, `dconf-editor` removed from
  desktop extras.
- Everything else (apt tuning, HashiCorp/1Password repos, base packages,
  fail2ban, ufw, sysctl, sudoers, fonts, Nerd Font, WirePlumber
  keep-awake, codecs, git config, bash/fish) carries over unchanged.

### roles/third-party changes vs Ubuntu

- Drop `multipass.yml`, `remove-snap.yml`, and `install_multipass`.
- Add, ported from Fedora:
  - `twingate.yml` — Twingate's apt repo instead of the RPM repo
    (`twingate_repo_url` var); post-install note to run `twingate setup`.
  - `cider.yml` — `sh.cider.Cider` flatpak from Flathub (unchanged logic;
    Flathub remote already present on Pop, task still ensures it).
  - `electron-apps.yml` — unchanged logic, `electron_apps_*` vars copied
    from Fedora; build dependencies switched to apt package names.
- `auto-cpufreq.yml` — fail with a clear message if `install_autocpu` is
  true and `system76-power` is active. Default stays `false`.
- Every other third-party task is reviewed for `distribution == 'Ubuntu'`
  checks and for repos that key on distribution name rather than codename.

### roles/cosmic

**Settings writer (`settings.yml`).** Data-driven, mirroring the dconf loop:

```yaml
cosmic_settings:
  - component: com.system76.CosmicTheme.Mode
    version: 1
    key: is_dark
    value: "true"
```

For each entry, ensure the directory exists and write the file with
`ansible.builtin.copy` (`content: value`), owned by `local_user`. `copy`
gives idempotence for free. Values are raw RON strings.

**The exact component IDs, versions, key names and RON values in this spec
are provisional.** They are confirmed in the VM before implementation (see
"Key capture" below), and the list in `vars.example.yml` is built from the
captured files, not from this document.

**Settings to carry over:**

| Behaviour | Provisional COSMIC location |
|---|---|
| Dark mode | `com.system76.CosmicTheme.Mode/v1/is_dark` |
| 12h clock | `com.system76.CosmicAppletTime/v1/military_time` = `false` |
| Touchpad: natural scroll off, tap-to-click off, clickfinger | `com.system76.CosmicComp/v1/input_touchpad` |
| Mouse natural scroll off | `com.system76.CosmicComp/v1/input_default` |
| Minimize + maximize buttons | `com.system76.CosmicTk/v1/show_minimize`, `show_maximize` |
| Workspaces only on primary display | `com.system76.CosmicComp/v1/workspaces` |
| Icon theme | `com.system76.CosmicTk/v1/icon_theme` |
| Battery percentage, automatic timezone | include only if a key exists |

**Layout (`layout.yml`).** Vars `cosmic_dock_enabled: false`,
`cosmic_panel_enabled: true`, `cosmic_autotile: false`. Implemented as
`cosmic_settings`-style writes to the panel entries config and the
compositor's autotile key (exact keys from capture).

**Keybindings (`keybindings.yml`).** `cosmic_custom_keybindings` keeps the
same shape as `gnome_custom_keybindings` (`name`, `binding`, `command`).
The task renders the whole custom-shortcuts RON file from a template, so
the vars list is authoritative and replaces any hand-made custom shortcuts.
`binding` uses COSMIC's modifier syntax (captured). Default list:

- 1Password Quick Access — Shift+Ctrl+Space
- Open File Manager — Super+E → `cosmic-files`
- Area Screenshot (annotate) — Shift+Alt+4 → `area-screenshot-annotate`
- Fullscreen Screenshot (to clipboard) — Shift+Alt+3 → `fullscreen-screenshot-clip`

**Theme (`theme.yml`).** Ported from Fedora's `dark-mode.yml` and
`icon-theme.yml`:
- `adw-gtk3` theme + GTK2/GTK3 `settings.ini` dark fallbacks and
  `gnome_cursor_size` → renamed `cosmic_cursor_size`.
- Qt/Electron env (`QT_QPA_PLATFORMTHEME=gtk3`, `QT_WAYLAND_DECORATION`,
  `ELECTRON_OZONE_PLATFORM_HINT=auto`) to `/etc/environment` and
  `~/.config/environment.d/`. Candidate-package probing kept, with Ubuntu
  package names.
- Colloid icons: clone + `install.sh` into `~/.local/share/icons`, copy
  `colloid_extra_icons`, create `colloid_icon_aliases`, then select via the
  COSMIC icon-theme key.
- Also sets `org.gnome.desktop.interface color-scheme 'prefer-dark'` via
  dconf, since GTK4/libadwaita apps and portals still read it on COSMIC.

**Screenshots (`screenshots.yml`).** Install `wl-clipboard`, the helper
scripts (`fullscreen-screenshot-clip`, `area-screenshot-annotate`,
`portal-screenshot-clip`) to `~/.local/bin`, and Satty from the pinned
upstream tarball (`satty_version`, `satty_sha256`). Capture backend:
whichever works under COSMIC in the VM — `grim`/`slurp` (wlr protocols)
or `cosmic-screenshot`/the portal. The chosen backend is recorded in the
helper script's comment.

**Notifications (`notifications.yml`).** Port only if COSMIC exposes a
per-app notification block; otherwise drop and list under "Not on
COSMIC".

### Dropped (documented in README under "Not on COSMIC")

- Fixed count of 5 workspaces (COSMIC workspaces are dynamic).
- Alt+Tab switching applications rather than windows.
- Weather and world-clock locations (GNOME app settings).
- GNOME Shell extensions: just-perfection, auto-move-windows,
  power-profile-switcher, auto-select-headset, silent-cycle-current-app,
  chrome-pwa-grouper.
- GNOME font overrides (Cantarell/DejaVu) — COSMIC defaults kept.
- Multipass (snap-only).

## Vars

`vars/vars.example.yml` = Ubuntu's file with:
- removed: `install_multipass`, `gnome_extensions`, `gnome_local_extensions`,
  `gnome_custom_keybindings`, `ubuntu_version`
- added from Fedora: `install_cider`, `install_twingate` (+ repo var),
  `install_electron_apps` + `electron_apps_*`, `install_colloid_icons` +
  `colloid_*`, `satty_*`, darkmode candidate pkgs/env (Ubuntu names)
- added new: `cosmic_settings`, `cosmic_custom_keybindings`,
  `cosmic_dock_enabled`, `cosmic_panel_enabled`, `cosmic_autotile`,
  `cosmic_cursor_size`, `popos_version: "24.04"`, `popos_skip_preflight`
- `local_user` default stays generic; `run.sh` passes `${USER}`.

## Error handling

Same patterns as the existing playbooks:
- Third-party repos probed before adding; installs skipped when absent.
- Optional packages (fonts, codecs, darkmode candidates) best-effort.
- Preflight assertion fails early with a clear message on non-Pop hosts.
- `cosmic` role skipped in containers (`common_is_container`), as `gnome` is
  today.
- `auto-cpufreq` refused when `system76-power` is active.

## Testing

**VM harness (`scripts/vm-test.sh`).** Downloads the Pop!_OS 24.04 ISO
(Intel/AMD variant), boots it in QEMU with OVMF (UEFI). One-time manual
install, then the disk is snapshotted as `base.qcow2`; each test run uses a
fresh overlay on top of it. Runs on a Linux host with KVM (pattern taken
from `ubuntu-desktop-vanilla/vm-test.sh`).

**Key capture (gates writing `roles/cosmic`).** On the clean VM:
`cp -r ~/.config/cosmic /tmp/before`, change every setting in the
carry-over table by hand in COSMIC Settings (and the dock/tiling toggles
and one custom shortcut), then `diff -r /tmp/before ~/.config/cosmic`. The
diff is the source of truth for `cosmic_settings` and the keybinding
template. Also record the preinstalled app list (`apt-mark showmanual`,
`flatpak list`) for the junk-app list.

**Automated.** ansible-lint + yamllint clean; Molecule converge +
idempotence on an Ubuntu 24.04 container with `popos_skip_preflight: true`
(covers `common` and `third-party`).

**Acceptance (on the VM, after a full `./run.sh` and re-login):**
- Second `./run.sh` reports `changed=0`.
- Dark theme, Colloid icons, top panel present, dock absent, tiling off.
- Touchpad/mouse scroll and click settings as specified.
- Chrome, Slack, VS Code, Zoom, 1Password, Twingate, Cider, Alacritty and
  each electron-app launch.
- Super+E opens COSMIC Files; Shift+Alt+3 puts a screenshot on the
  clipboard; Shift+Alt+4 opens Satty.
- A Qt app and an Electron app render dark.

## Out of scope

- Unattended Pop!_OS ISO builder.
- NVIDIA-specific setup (Pop's NVIDIA ISO already handles drivers).
- Publishing the GitHub remote / CI wiring beyond what is cloned from the
  Ubuntu repo (CircleCI config updated to the new repo name only).
