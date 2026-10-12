# Pop!_OS 24.04 + COSMIC Workstation Playbook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn this clone of `ansible-ubuntu-workstation-base` into a playbook that configures a Pop!_OS 24.04 laptop running COSMIC to the same opinionated state as the Ubuntu and Fedora playbooks.

**Architecture:** Keep the `common` and `third-party` roles from Ubuntu (apt-based, Pop is noble underneath), remove snap/WSL/GNOME-only pieces, port the Fedora-only extras, and replace `roles/gnome` with a new `roles/cosmic` that writes COSMIC's one-file-per-setting RON config under `~/.config/cosmic/`. COSMIC key names and values come from a capture on a real Pop!_OS 24.04 VM (Task 5), not from memory.

**Tech Stack:** Ansible (ansible-core via pipx), `community.general`, `ansible.posix`, Molecule (podman driver, `ubuntu:24.04` image), ansible-lint, yamllint, shellcheck, QEMU + OVMF for the VM.

**Spec:** `docs/superpowers/specs/2026-10-11-popos-cosmic-playbook-design.md`

**Repo root (all paths below are relative to it):** `/Users/mike.tharpe/src/github/mtharpe/ansible-popos-workstation-base`

**Reference repos (read-only sources for ported files):**
- Fedora: `/Users/mike.tharpe/src/github/mtharpe/ansible-fedora-workstation-base` (referred to as `$FEDORA`)
- Ubuntu ISO builder (VM script pattern): `/Users/mike.tharpe/src/github/mtharpe/ubuntu-desktop-vanilla`

**Local tooling needed:** `ansible-core`, `ansible-lint`, `yamllint`, `molecule` + `molecule-plugins[podman]`, `podman` (running machine), `shellcheck`, `qemu`. Install on macOS with `brew install ansible ansible-lint yamllint shellcheck podman qemu && pipx install molecule --include-deps && pipx inject molecule "molecule-plugins[podman]"`, then `podman machine init && podman machine start` if no machine exists.

## Global Constraints

- Target OS: Pop!_OS 24.04 LTS with COSMIC. `ansible_facts['distribution']` is `Pop!_OS`, `distribution_major_version` is `24`, `distribution_release` is `noble`.
- No snapd on Pop; never install snapd. Multipass is dropped.
- No GNOME Shell extensions of any kind.
- Desktop layout defaults: `cosmic_panel_enabled: true`, `cosmic_dock_enabled: false`, `cosmic_autotile: false`.
- COSMIC config path: `/home/{{ local_user }}/.config/cosmic/<component>/v<N>/<key>`, file content is a raw RON value, files and directories owned by `local_user`.
- The custom shortcuts file is authoritative: the vars list replaces any hand-made custom shortcuts.
- Every COSMIC component/key/RON value in `vars/vars.example.yml` and templates must match `docs/cosmic-keys.md` (Task 5 output). Values in this plan before Task 5 are provisional.
- Third-party repos are probed before being added; installs skip when the probe fails (existing pattern).
- `cosmic` role and dconf writes are skipped in containers (`common_is_container`).
- ansible-core >= 2.19 (`run.sh` installs the latest via pipx). Older cores literal-eval templated strings like `["Panel"]` or `"Colloid-Dark"` into lists/unquoted strings, corrupting RON values.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Out of scope: ISO builder, NVIDIA setup, creating the GitHub remote.

## Review Focus

1. **Junk-app purge cascading into the desktop.** Purging `firefox`/`libreoffice-*` with `autoremove: true` on Pop can remove the `pop-desktop` metapackage and then autoremove COSMIC itself. Expected: the run stops before purging if a simulation shows any protected package (`pop-desktop`, `cosmic-session`, `cosmic-comp`) would be removed. Test: Task 2 Step 1 (molecule verify).
2. **Config written as root.** If `~/.config/cosmic/...` dirs/files end up root-owned, COSMIC silently fails to save settings changed later in the GUI. Expected: everything under `~/.config/cosmic` owned by `local_user`. Test: Task 6 Step 2 (ownership asserts).
3. **Running over SSH / outside a graphical session.** The VM workflow runs `./run.sh` over SSH where there is no session D-Bus. Expected: the run succeeds (COSMIC writes are plain files; dconf writes go through `community.general.dconf`'s `dbus-run-session` fallback). Test: Task 10 Step 2 runs provisioning over SSH.
4. **Re-running after hand edits.** A user changes a COSMIC setting or adds a custom shortcut in the GUI, then re-runs. Expected: only keys listed in vars are reset; custom shortcuts are replaced wholesale (documented). Test: Task 10 Step 5.
5. **Wrong host.** Someone runs it on Ubuntu, Fedora, macOS, or Pop 22.04 (GNOME-based). Expected: fail in the first task with a message naming the detected distro/version, unless `popos_skip_preflight: true`. Test: Task 2 Steps 3–4 (negative run on the dev machine) and Task 10 Step 2 (positive on the VM).

---

### Task 1: Strip Ubuntu-only pieces and rebrand

**Files:**
- Delete: `run_wsl.sh`, `setup_wsl.yml`, `vars/vars.wsl.example.yml`, `roles/third-party/tasks/multipass.yml`, `roles/gnome/` (entire directory)
- Modify: `roles/third-party/tasks/main.yml` (remove Multipass block), `roles/common/tasks/packages.yml` (desktop extras list; remove Firefox/Thunderbird launcher hiding), `vars/vars.example.yml`, `setup_workstation.yml`, `molecule/default/converge.yml`, `molecule/docker/converge.yml`, `meta/main.yml`, `Makefile`, `.gitignore`, `.circleci/config.yml`

**Interfaces:**
- Produces: `setup_workstation.yml` running roles `common`, `third-party` (Task 6 adds `cosmic`); var `popos_version: "24.04"` replacing `ubuntu_version`.

- [ ] **Step 1: Write the failing check**

Create `tests/no-ubuntu-leftovers.sh`:

```bash
#!/usr/bin/env bash
# Fails if any Ubuntu/GNOME-only artefact survived the Pop!_OS port.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
for path in run_wsl.sh setup_wsl.yml vars/vars.wsl.example.yml \
            roles/third-party/tasks/multipass.yml roles/gnome; do
  if [ -e "${path}" ]; then
    echo "leftover: ${path}"
    fail=1
  fi
done

if grep -rnE 'install_multipass|gnome_extensions|gnome_local_extensions|gnome_custom_keybindings|ubuntu_version|role: gnome|gnome-tweaks|gnome-extensions-app|dconf-editor|firefox_firefox\.desktop' \
     setup_workstation.yml roles vars molecule Makefile; then
  echo "leftover references above"
  fail=1
fi

exit "${fail}"
```

Run: `chmod +x tests/no-ubuntu-leftovers.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/no-ubuntu-leftovers.sh`
Expected: exit 1, lists `leftover: run_wsl.sh`, `leftover: roles/gnome`, and grep hits in `vars/vars.example.yml`.

- [ ] **Step 3: Delete the Ubuntu-only files**

```bash
git rm -q run_wsl.sh setup_wsl.yml vars/vars.wsl.example.yml roles/third-party/tasks/multipass.yml
git rm -rq roles/gnome
```

- [ ] **Step 4: Remove the Multipass block from `roles/third-party/tasks/main.yml`**

Delete these lines at the end of the file:

```yaml
- name: Setup Multipass
  ansible.builtin.import_tasks: multipass.yml
  when: install_multipass | default(false)
```

- [ ] **Step 5: Edit `roles/common/tasks/packages.yml`**

Replace the "Desktop-only extras" comment and task with:

```yaml
# Desktop-only extras: GUI apps.
# alacritty intentionally NOT here: Ubuntu 24.04 ships 0.13.2, but our
# alacritty.toml uses the [terminal] / [general] sections introduced in
# 0.14. We install alacritty from ppa:aslatter/ppa in the third-party
# alacritty role instead.
- name: Install desktop extras
  ansible.builtin.apt:
    name:
      - transmission
      - mpv
      - celluloid
      - nextcloud-desktop
    state: present
    cache_valid_time: 3600
  become: true
  when: install_desktop_extras | default(true)
```

Delete the two tasks after "Uninstall junk apps" — the comment block starting `# Ubuntu ships Firefox and Thunderbird as snaps`, `Ensure user applications directory exists`, and `Hide Firefox and Thunderbird launchers from GNOME Shell` (to the end of the file). Pop ships Firefox as a deb, so the apt purge covers it. (The purge task itself is moved and guarded in Task 2.)

- [ ] **Step 6: Edit `vars/vars.example.yml`**

1. Replace the desktop extras comment with:

```yaml
# Desktop extras: GUI apps (nextcloud-desktop, celluloid, mpv, transmission),
# VA-API hardware video accel, GStreamer media codecs, WirePlumber ALSA config,
# and the junk-app purge. Set false on a headless box.
install_desktop_extras: true
```

2. Delete the line `install_multipass: true`.
3. Delete the `gnome_extensions:` block, the `gnome_local_extensions:` block, and the `gnome_custom_keybindings:` block, with their comments. (Task 6 adds `cosmic_custom_keybindings`.)
4. Replace:

```yaml
# Ubuntu target version (used for pinning images / docs)
ubuntu_version: "24.04"
```

with:

```yaml
# Pop!_OS target version, checked by roles/common/tasks/preflight.yml.
popos_version: "24.04"
```

- [ ] **Step 7: Edit `setup_workstation.yml`**

```yaml
---
- name: Setup Workstation
  hosts: workstation
  become: true
  gather_facts: true

  vars_files:
    - vars/vars.yml

  roles:
    - common
    - third-party

  handlers:
    - name: Import shared handlers
      ansible.builtin.import_tasks: handlers/main.yml
```

- [ ] **Step 8: Edit both molecule converge files**

In `molecule/default/converge.yml` and `molecule/docker/converge.yml`, delete:

```yaml
    - role: gnome
      when: not common_is_container | default(false)
```

- [ ] **Step 9: Rebrand metadata**

`meta/main.yml`:

```yaml
galaxy_info:
  role_name: popos_workstation_base   # use underscores, not dashes
  namespace: mtharpe            # use your Galaxy namespace or GitHub username
  author: Michael Tharpe
  description: Pop!_OS 24.04 (COSMIC) Workstation Base
  license: MIT
  min_ansible_version: "2.10"
  platforms:
    - name: Ubuntu
      versions:
        - noble
```

`Makefile`: change `IMAGE_NAME := custom-ubuntu-ansible` to `IMAGE_NAME := custom-popos-ansible`.

`.gitignore`: append

```
# QEMU test VM disks, firmware vars and ISOs (scripts/vm-test.sh)
vm/
```

`.circleci/config.yml`: in the `shellcheck` job's `command`, after `shellcheck run.sh` add the line `shellcheck tests/*.sh`.

- [ ] **Step 10: Run the checks to verify they pass**

Run: `tests/no-ubuntu-leftovers.sh && ansible-playbook --syntax-check setup_workstation.yml && ansible-lint . && yamllint .`
Expected: no leftovers, `playbook: setup_workstation.yml`, ansible-lint `Passed`, yamllint no errors.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "chore: strip WSL, Multipass, snap shadowing and GNOME role for Pop!_OS port

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Preflight assertion and guarded junk-app purge

**Files:**
- Create: `roles/common/tasks/preflight.yml`, `roles/common/tasks/junk-apps.yml`, `tests/preflight.yml`, `molecule/default/verify.yml`
- Modify: `roles/common/tasks/main.yml`, `roles/common/tasks/packages.yml` (move purge out), `vars/vars.example.yml`, `molecule/default/converge.yml`, `molecule/docker/converge.yml`

**Interfaces:**
- Produces: vars `popos_skip_preflight` (bool, default `false`), `popos_protected_packages` (list[str]), `common_junk_packages` (list[str]); task file `roles/common/tasks/junk-apps.yml` callable via `include_role: name=common tasks_from=junk-apps.yml`.

- [ ] **Step 1: Write the failing tests**

Create `tests/preflight.yml`:

```yaml
---
# Run from the repo root:
#   ANSIBLE_ROLES_PATH=roles ansible-playbook tests/preflight.yml
# On any non-Pop!_OS host this must FAIL with the preflight message, and must
# PASS when given -e popos_skip_preflight=true.
- name: Exercise the Pop!_OS preflight check
  hosts: localhost
  connection: local
  gather_facts: true
  vars:
    popos_version: "24.04"
  tasks:
    - name: Run preflight
      ansible.builtin.include_role:
        name: common
        tasks_from: preflight.yml
```

Create `molecule/default/verify.yml`:

```yaml
---
- name: Verify common + third-party
  hosts: all
  become: true
  gather_facts: true
  tasks:
    # Review Focus 1: a purge that would take a protected package with it must
    # stop before anything is removed. python3-minimal's reverse deps include
    # python3, which stands in for pop-desktop here.
    - name: Attempt a purge that would cascade into a protected package
      block:
        - name: Run the junk-app purge with a cascading package
          ansible.builtin.include_role:
            name: common
            tasks_from: junk-apps.yml
          vars:
            common_junk_packages: [python3-minimal]
            popos_protected_packages: [python3]
        - name: Record that the guard did not fire
          ansible.builtin.set_fact:
            verify_guard_fired: false
      rescue:
        - name: Record that the guard fired
          ansible.builtin.set_fact:
            verify_guard_fired: true

    - name: Assert the guard stopped the purge
      ansible.builtin.assert:
        that: verify_guard_fired
        fail_msg: junk-apps.yml purged a package whose removal cascades into a protected package

    - name: Check python3 is still installed
      ansible.builtin.command: dpkg-query -W -f='${db:Status-Abbrev}' python3
      register: verify_python3
      changed_when: false

    - name: Assert python3 survived
      ansible.builtin.assert:
        that: verify_python3.stdout is match('ii')
```

- [ ] **Step 2: Run them to verify they fail**

Run: `ANSIBLE_ROLES_PATH=roles ansible-playbook tests/preflight.yml`
Expected: FAIL — `Could not find specified file in role: tasks/preflight.yml`.

Run: `make reset && MOLECULE_GLOB=molecule/default/molecule.yml molecule test -s default`
Expected: converge passes, verify FAILS with `Could not find specified file in role: tasks/junk-apps.yml`.

- [ ] **Step 3: Write `roles/common/tasks/preflight.yml`**

```yaml
---
# Stop before touching anything when this isn't the OS the playbook targets.
# Pop!_OS 22.04 is GNOME-based and would get a half-applied COSMIC config;
# plain Ubuntu has no COSMIC at all. Molecule sets popos_skip_preflight
# because its test container is stock ubuntu:24.04.
- name: Assert the host is Pop!_OS {{ popos_version }}
  ansible.builtin.assert:
    that:
      - ansible_facts['distribution'] == 'Pop!_OS'
      - ansible_facts['distribution_version'] == popos_version
    fail_msg: >-
      This playbook targets Pop!_OS {{ popos_version }} (COSMIC). Detected
      {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] | default('unknown') }}.
      Set popos_skip_preflight=true only for container tests.
    quiet: true
  when: not popos_skip_preflight | default(false)
  tags: [always]
```

- [ ] **Step 4: Write `roles/common/tasks/junk-apps.yml`**

```yaml
---
# Purge preinstalled apps we don't want, without letting apt's dependency
# resolution take the desktop with them. On Pop!_OS the pop-desktop
# metapackage may depend on some of these; purging one removes pop-desktop,
# and autoremove then sweeps away everything only it was holding — which can
# include COSMIC. So: simulate first, refuse if a protected package appears
# in the simulated removals, and only then purge for real.
- name: Find which junk packages are installed
  ansible.builtin.shell:
    cmd: >-
      dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n'
      {{ common_junk_packages | map('quote') | join(' ') }} 2>/dev/null
      | awk '$1 == "ii" { print $2 }'
  register: common_junk_installed
  changed_when: false
  failed_when: false
  tags: [junk]

- name: Simulate purging the installed junk packages
  ansible.builtin.command:
    cmd: >-
      apt-get -s purge --autoremove
      {{ common_junk_installed.stdout_lines | map('quote') | join(' ') }}
  register: common_junk_simulation
  changed_when: false
  when: common_junk_installed.stdout_lines | length > 0
  tags: [junk]

- name: Collect packages the simulation would remove
  ansible.builtin.set_fact:
    common_junk_would_remove: >-
      {{ common_junk_simulation.stdout_lines | default([])
         | select('match', '^(Purg|Remv) ')
         | map('regex_replace', '^(?:Purg|Remv) (\S+).*$', '\1')
         | list }}
  tags: [junk]

- name: Refuse a purge that would remove the desktop
  ansible.builtin.assert:
    that: common_junk_would_remove | intersect(popos_protected_packages) | length == 0
    fail_msg: >-
      Purging {{ common_junk_installed.stdout_lines | join(', ') }} would also remove
      {{ common_junk_would_remove | intersect(popos_protected_packages) | join(', ') }}.
      Drop the offending package from common_junk_packages.
  tags: [junk]

- name: Purge the junk packages
  ansible.builtin.apt:
    name: "{{ common_junk_installed.stdout_lines }}"
    state: absent
    purge: true
    autoremove: true
  become: true
  when: common_junk_installed.stdout_lines | length > 0
  tags: [junk]
```

- [ ] **Step 5: Replace the old purge task in `roles/common/tasks/packages.yml`**

Delete the whole `# Uninstall unwanted apps` / `- name: Uninstall junk apps` task. Then in `roles/common/tasks/main.yml` make the start and the package section read:

```yaml
---
- name: Preflight
  ansible.builtin.import_tasks: preflight.yml

- name: Detect container environment
```

(keep the existing container/WSL detection and imports), and directly after `- name: Setup Packages` add:

```yaml
- name: Purge unwanted preinstalled apps
  ansible.builtin.import_tasks: junk-apps.yml
  when: install_desktop_extras | default(true)
```

- [ ] **Step 6: Add vars to `vars/vars.example.yml`** (after `install_desktop_extras`)

```yaml
# Skip the Pop!_OS host check (roles/common/tasks/preflight.yml). Only for
# container tests — the playbook assumes Pop!_OS + COSMIC everywhere else.
popos_skip_preflight: false

# Preinstalled apps purged on desktop installs. Reconciled against the Pop!_OS
# 24.04 preinstalled list in docs/cosmic-keys.md (Task 5).
common_junk_packages:
  - firefox
  - thunderbird
  - libreoffice-core
  - libreoffice-common
  - libreoffice-writer
  - libreoffice-calc
  - libreoffice-impress
  - libreoffice-draw
  - libreoffice-base-core
  - libreoffice-math
  - rhythmbox
  - totem
  - vlc
  - gnome-calendar
  - gnome-contacts
  - gnome-maps
  - gnome-logs

# The junk purge refuses to run if apt would remove any of these with it.
popos_protected_packages:
  - pop-desktop
  - cosmic-session
  - cosmic-comp
```

Because molecule's converge doesn't load `vars/vars.example.yml`, also add defaults: in `roles/common/tasks/junk-apps.yml` nothing changes (callers pass vars), and in both `molecule/*/converge.yml` add to `vars:`:

```yaml
    popos_skip_preflight: true
    common_junk_packages: [vlc]
    popos_protected_packages: [pop-desktop, cosmic-session, cosmic-comp]
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `ANSIBLE_ROLES_PATH=roles ansible-playbook tests/preflight.yml`
Expected: FAIL with `This playbook targets Pop!_OS 24.04 (COSMIC). Detected MacOSX ...` (or your dev OS) — this failure is the pass condition.

Run: `ANSIBLE_ROLES_PATH=roles ansible-playbook tests/preflight.yml -e popos_skip_preflight=true`
Expected: `failed=0`.

Run: `MOLECULE_GLOB=molecule/default/molecule.yml molecule test -s default`
Expected: converge, idempotence and verify all pass; verify shows `Assert the guard stopped the purge` ok.

Run: `ansible-lint . && yamllint .`
Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(common): Pop!_OS preflight and desktop-safe junk-app purge

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Port the Fedora third-party extras and Pop-proof existing tasks

**Files:**
- Create: `roles/third-party/tasks/twingate.yml`, `roles/third-party/tasks/cider.yml`, `roles/third-party/tasks/electron-apps.yml`
- Modify: `roles/third-party/tasks/main.yml`, `roles/third-party/tasks/auto-cpufreq.yml`, `roles/third-party/tasks/eza.yml:4`, `roles/third-party/tasks/alacritty.yml` (icon probe + hidden launchers), `vars/vars.example.yml`, `molecule/default/converge.yml`, `molecule/docker/converge.yml`, `molecule/default/verify.yml`

**Interfaces:**
- Consumes: `common_is_container` fact from `roles/common/tasks/main.yml`.
- Produces: vars `install_twingate`, `twingate_repo_url`, `install_cider`, `install_electron_apps`, `electron_apps_*`. Task 7 relies on `electron_apps_slugs` matching `colloid_extra_icons`.

- [ ] **Step 1: Find the Twingate apt repo index file**

Run: `curl -sI https://packages.twingate.com/apt/Release | head -1; curl -sI https://packages.twingate.com/apt/Packages | head -1`
Expected: at least one `HTTP/2 200`. Use the first one that returns 200 as `<INDEX>` in Step 4 (`Release` if both do). If neither returns 200, run `curl -fsSL https://binaries.twingate.com/client/linux/install.sh | grep -n apt` and use the repo line it writes.

- [ ] **Step 2: Write the failing test**

Append to `molecule/default/verify.yml`:

```yaml
    - name: Read the Twingate apt candidate
      ansible.builtin.command: apt-cache policy twingate
      register: verify_twingate_policy
      changed_when: false

    - name: Assert the Twingate repo resolves a candidate
      ansible.builtin.assert:
        that: verify_twingate_policy.stdout is search('Candidate:\s+(?!\(none\))\S+')
        fail_msg: "{{ verify_twingate_policy.stdout }}"
```

In both `molecule/*/converge.yml` add to `vars:`:

```yaml
    install_twingate: true
    twingate_repo_url: "https://packages.twingate.com/apt/"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `MOLECULE_GLOB=molecule/default/molecule.yml molecule test -s default`
Expected: verify FAILS at `Assert the Twingate repo resolves a candidate` (`Candidate: (none)` or empty output).

- [ ] **Step 4: Write `roles/third-party/tasks/twingate.yml`**

Replace `<INDEX>` with the file name chosen in Step 1.

```yaml
---
# Twingate zero-trust client.
#
# Upstream's apt repo is a flat repo with no published signing key; Twingate's
# own installer (binaries.twingate.com/client/linux/install.sh) adds it with
# [trusted=yes]. Packages are trusted on TLS alone — by upstream's design, not
# by choice here. Set install_twingate: false if that tradeoff is not
# acceptable on a given machine.
#
# Installing only lays down the client; `twingate setup` still has to be run
# once interactively to join a network.

- name: Probe Twingate apt repo
  ansible.builtin.uri:
    url: "{{ twingate_repo_url }}<INDEX>"
    method: HEAD
    status_code: [200, 301, 302]
  register: thirdparty_twingate_probe
  failed_when: false
  changed_when: false
  tags: [third_party, twingate]

- name: Note unreachable Twingate repo
  ansible.builtin.debug:
    msg: "Twingate apt repo unreachable — skipping."
  when: thirdparty_twingate_probe.status | default(0) != 200
  tags: [third_party, twingate]

- name: Add Twingate apt repository
  ansible.builtin.copy:
    dest: /etc/apt/sources.list.d/twingate.list
    content: "deb [trusted=yes] {{ twingate_repo_url }} /\n"
    owner: root
    group: root
    mode: "0644"
  become: true
  register: thirdparty_twingate_repo
  when: thirdparty_twingate_probe.status | default(0) == 200
  tags: [third_party, twingate]

- name: Refresh apt metadata for Twingate
  ansible.builtin.apt:
    update_cache: true
  become: true
  changed_when: false
  when: thirdparty_twingate_repo is changed
  tags: [third_party, twingate]

# Not in containers: the package's postinst manages a systemd unit.
- name: Install Twingate
  ansible.builtin.apt:
    name: twingate
    state: present
  become: true
  when:
    - thirdparty_twingate_probe.status | default(0) == 200
    - not common_is_container | default(false)
  tags: [third_party, twingate]
```

- [ ] **Step 5: Write `roles/third-party/tasks/cider.yml`**

```yaml
---
# Cider — Apple Music client. Upstream ships no deb; the sanctioned Linux
# install path is the Flathub flatpak (`sh.cider.Cider`). Pop!_OS ships
# Flatpak with Flathub configured, but the remote is still ensured here so the
# task doesn't depend on that default.

- name: Ensure the flathub remote is available (system)
  community.general.flatpak_remote:
    name: flathub
    flatpakrepo_url: https://flathub.org/repo/flathub.flatpakrepo
    state: present
    method: system
  become: true
  tags: [third_party, cider]

- name: Install Cider
  community.general.flatpak:
    name: sh.cider.Cider
    state: present
    method: system
  become: true
  tags: [third_party, cider]
```

- [ ] **Step 6: Write `roles/third-party/tasks/electron-apps.yml`**

Copy `$FEDORA/roles/third-party/tasks/electron-apps.yml` verbatim, then change only the first task to apt and drop the two Fedora-history migration tasks (`Migrate legacy linux-google-apps checkout to electron-apps`, `Migrate legacy google-apps revision stamp`) — a fresh Pop install has nothing to migrate:

```bash
cp "$FEDORA/roles/third-party/tasks/electron-apps.yml" roles/third-party/tasks/electron-apps.yml
```

Then replace the first task with:

```yaml
- name: Install Electron web app build dependencies
  ansible.builtin.apt:
    name:
      - git
      - npm          # pulls nodejs; build-linux.sh drives npx electron-packager
      - imagemagick  # used to render the icon size ladder
    state: present
  become: true
  tags: [third_party, electron-apps]
```

and in the header comment change `roles/gnome's colloid_extra_icons` to `roles/cosmic's colloid_extra_icons`.

- [ ] **Step 7: Guard auto-cpufreq against system76-power**

Insert at the top of `roles/third-party/tasks/auto-cpufreq.yml` (after `---`):

```yaml
# Pop!_OS manages CPU governors and power profiles with system76-power.
# auto-cpufreq fights it for the same knobs, so refuse rather than install a
# second power manager.
- name: Check whether system76-power is active
  ansible.builtin.command: systemctl is-active system76-power
  register: thirdparty_s76_power
  changed_when: false
  failed_when: false
  tags: [third_party, autocpu]

- name: Refuse auto-cpufreq alongside system76-power
  ansible.builtin.assert:
    that: thirdparty_s76_power.stdout | trim != 'active'
    fail_msg: >-
      install_autocpu is true but system76-power is active. Pop!_OS already
      manages CPU power; set install_autocpu: false.
  tags: [third_party, autocpu]
```

- [ ] **Step 8: Make eza and Alacritty Pop-aware**

`roles/third-party/tasks/eza.yml` line 4: change `(ansible_facts['distribution'] | default('')) == 'Ubuntu'` to `(ansible_facts['distribution'] | default('')) in ['Ubuntu', 'Pop!_OS']`.

`roles/third-party/tasks/alacritty.yml`:
- in the `find` expression add `-o -name 'com.system76.CosmicTerm.*'` before `-o -name 'Alacritty.*'`, and change the `for name in` list to `for name in com.system76.CosmicTerm org.gnome.Ptyxis org.gnome.Console org.gnome.Terminal Alacritty utilities-terminal; do`.
- rename the task `Hide default distro terminal launchers from GNOME Shell` to `Hide default distro terminal launchers` and add `- com.system76.CosmicTerm.desktop` as the first loop item.

- [ ] **Step 9: Wire tasks and vars**

Append to `roles/third-party/tasks/main.yml`:

```yaml
- name: Setup Twingate
  ansible.builtin.import_tasks: twingate.yml
  when: install_twingate | default(false)

- name: Setup Cider
  ansible.builtin.import_tasks: cider.yml
  when: install_cider | default(false)

- name: Setup Electron web apps
  ansible.builtin.import_tasks: electron-apps.yml
  when: install_electron_apps | default(false)
```

In `vars/vars.example.yml` after `install_zoom: true` add:

```yaml
# Cider — Apple Music client, installed as the sh.cider.Cider flatpak.
install_cider: true
# Twingate zero-trust client. Upstream's apt repo is unsigned ([trusted=yes]).
# After install, run `twingate setup` once to join a network.
install_twingate: true
twingate_repo_url: "https://packages.twingate.com/apt/"
```

and after `install_kubectl: true` add:

```yaml
# Standalone Electron web apps built from https://github.com/mtharpe/electron-apps
# and installed under ~/.local. First run downloads Electron and packages every
# slug below, so it is slow; later runs skip the build unless the checkout
# moved or an app is missing.
install_electron_apps: true
electron_apps_repo: https://github.com/mtharpe/electron-apps.git
electron_apps_version: main
electron_apps_src: "/home/{{ local_user }}/.local/src/electron-apps"
electron_apps_prefix: "/home/{{ local_user }}/.local"
# Authoritative build list (passed to build-linux.sh). Keep in step with
# colloid_extra_icons / colloid_icon_aliases in the cosmic section.
electron_apps_slugs:
  - gmail
  - google-calendar
  - google-tasks
  - google-keep
  - google-messages
  - messenger
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `MOLECULE_GLOB=molecule/default/molecule.yml molecule test -s default && ansible-lint . && yamllint .`
Expected: all pass; verify shows the Twingate candidate assert ok.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat(third-party): add Twingate, Cider, electron-apps; guard auto-cpufreq on Pop

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: QEMU harness for a Pop!_OS 24.04 VM

**Files:**
- Create: `scripts/vm-test.sh`, `tests/vm-test-dryrun.sh`

**Interfaces:**
- Produces: `scripts/vm-test.sh {fetch|install|run|reset|sync|provision}`; VM reachable by SSH on `localhost:${SSH_PORT:-2222}`; repo synced to `~/ansible-popos-workstation-base` in the VM. Tasks 5 and 10 use these subcommands.

- [ ] **Step 1: Write the failing test**

Create `tests/vm-test-dryrun.sh`:

```bash
#!/usr/bin/env bash
# Exercises scripts/vm-test.sh without booting anything.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

out="$(DRY_RUN=1 VM_DIR="${tmp}" scripts/vm-test.sh run)"
grep -q 'hostfwd=tcp::2222-:22' <<<"${out}" || { echo "run: no SSH forward"; exit 1; }
grep -q "${tmp}/run.qcow2" <<<"${out}" || { echo "run: not booting the overlay"; exit 1; }

out="$(DRY_RUN=1 VM_DIR="${tmp}" ISO=/x/pop.iso scripts/vm-test.sh install)"
grep -q '/x/pop.iso' <<<"${out}" || { echo "install: ISO not attached"; exit 1; }
grep -q "${tmp}/base.qcow2" <<<"${out}" || { echo "install: not using base disk"; exit 1; }

if scripts/vm-test.sh bogus >/dev/null 2>&1; then
  echo "unknown subcommand should fail"; exit 1
fi
echo ok
```

Run: `chmod +x tests/vm-test-dryrun.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/vm-test-dryrun.sh`
Expected: FAIL — `scripts/vm-test.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/vm-test.sh`**

```bash
#!/usr/bin/env bash
# QEMU harness for testing this playbook on a Pop!_OS 24.04 VM.
#
#   scripts/vm-test.sh fetch      download the Pop!_OS 24.04 (Intel/AMD) ISO into vm/
#   scripts/vm-test.sh install    boot the ISO against vm/base.qcow2; install Pop by hand
#   scripts/vm-test.sh run        boot a throwaway overlay on top of base.qcow2
#   scripts/vm-test.sh reset      discard the overlay so the next `run` starts clean
#   scripts/vm-test.sh sync       rsync this repo into ~/ansible-popos-workstation-base in the VM
#   scripts/vm-test.sh provision  sync, then run ./run.sh in the VM over SSH
#
# Env: ISO, VM_DIR (./vm), MEM_MB (8192), CPUS (4), DISPLAY_OPT (default),
#      SSH_PORT (2222), VM_USER ($USER), ACCEL (auto: kvm/hvf/tcg),
#      OVMF_CODE / OVMF_VARS_TEMPLATE (auto-detected), DRY_RUN=1 (print qemu cmd).
#
# base.qcow2 stays pristine after the manual install; every `run` boots an
# overlay (run.qcow2) so a test can be thrown away with `reset`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VM_DIR="${VM_DIR:-${HERE}/vm}"
ISO="${ISO:-${VM_DIR}/pop-os-24.04.iso}"
BASE="${VM_DIR}/base.qcow2"
BASE_VARS="${VM_DIR}/base_VARS.fd"
OVERLAY="${VM_DIR}/run.qcow2"
RUN_VARS="${VM_DIR}/run_VARS.fd"
DISK_SIZE="${DISK_SIZE:-60G}"
MEM_MB="${MEM_MB:-8192}"
CPUS="${CPUS:-4}"
DISPLAY_OPT="${DISPLAY_OPT:-default}"
SSH_PORT="${SSH_PORT:-2222}"
VM_USER="${VM_USER:-${USER}}"
DRY_RUN="${DRY_RUN:-0}"
REMOTE_DIR="ansible-popos-workstation-base"
SSH_OPTS=(-p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

detect_accel() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo kvm ;;
    Darwin-x86_64) echo hvf ;;
    *) echo tcg ;;
  esac
}
ACCEL="${ACCEL:-$(detect_accel)}"

find_first() {
  local f
  for f in "$@"; do
    if [ -f "${f}" ]; then echo "${f}"; return 0; fi
  done
  return 1
}

firmware() {
  OVMF_CODE="${OVMF_CODE:-$(find_first \
    /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd || true)}"
  OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-$(find_first \
    /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /opt/homebrew/share/qemu/edk2-i386-vars.fd /usr/local/share/qemu/edk2-i386-vars.fd || true)}"
  if [ "${DRY_RUN}" = 1 ]; then
    OVMF_CODE="${OVMF_CODE:-OVMF_CODE.fd}"
    OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-OVMF_VARS.fd}"
    return
  fi
  if [ -z "${OVMF_CODE}" ] || [ -z "${OVMF_VARS_TEMPLATE}" ]; then
    echo "OVMF UEFI firmware not found. Linux: apt install ovmf. macOS: brew install qemu." >&2
    echo "Or set OVMF_CODE and OVMF_VARS_TEMPLATE." >&2
    exit 1
  fi
  command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found" >&2; exit 1; }
  if [ "${ACCEL}" = tcg ]; then
    echo "WARNING: no hardware acceleration for x86_64 on this host (ACCEL=tcg)." >&2
    echo "         COSMIC will be very slow. Prefer a Linux x86_64 host with KVM." >&2
  fi
}

# boot <disk> <vars> [extra qemu args...]
boot() {
  local disk="$1" vars="$2"
  shift 2
  local cpu=host
  [ "${ACCEL}" = tcg ] && cpu=max
  local cmd=(qemu-system-x86_64
    -machine "type=q35,accel=${ACCEL}" -cpu "${cpu}"
    -m "${MEM_MB}" -smp "${CPUS}"
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${vars}"
    -drive "file=${disk},format=qcow2,if=none,id=disk0"
    -device virtio-blk-pci,drive=disk0,bootindex=1
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    -device virtio-net-pci,netdev=net0
    -device virtio-vga
    -display "${DISPLAY_OPT}"
    "$@")
  if [ "${DRY_RUN}" = 1 ]; then
    printf '%q ' "${cmd[@]}"
    echo
    return
  fi
  exec "${cmd[@]}"
}

cmd_fetch() {
  mkdir -p "${VM_DIR}"
  local meta url sha
  meta="$(curl -fsSL https://api.pop-os.org/builds/24.04/intel)"
  url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])' <<<"${meta}")"
  sha="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sha_sum"])' <<<"${meta}")"
  echo "==> ${url}"
  curl -fL --continue-at - -o "${ISO}" "${url}"
  echo "${sha}  ${ISO}" | shasum -a 256 -c -
}

cmd_install() {
  firmware
  if [ "${DRY_RUN}" != 1 ]; then
    [ -f "${ISO}" ] || { echo "No ISO at ${ISO}; run: scripts/vm-test.sh fetch" >&2; exit 1; }
    mkdir -p "${VM_DIR}"
    [ -f "${BASE}" ] || qemu-img create -f qcow2 "${BASE}" "${DISK_SIZE}" >/dev/null
    [ -f "${BASE_VARS}" ] || cp "${OVMF_VARS_TEMPLATE}" "${BASE_VARS}"
  fi
  boot "${BASE}" "${BASE_VARS}" \
    -drive "file=${ISO},format=raw,if=none,id=cd0,media=cdrom" \
    -device ide-cd,drive=cd0,bootindex=2
}

cmd_run() {
  firmware
  if [ "${DRY_RUN}" != 1 ]; then
    [ -f "${BASE}" ] || { echo "No base disk; run: scripts/vm-test.sh install" >&2; exit 1; }
    if [ ! -f "${OVERLAY}" ]; then
      qemu-img create -f qcow2 -b "${BASE}" -F qcow2 "${OVERLAY}" >/dev/null
      cp "${BASE_VARS}" "${RUN_VARS}"
    fi
  fi
  boot "${OVERLAY}" "${RUN_VARS}"
}

cmd_reset() {
  rm -f "${OVERLAY}" "${RUN_VARS}"
  echo "==> overlay discarded; next 'run' starts from base.qcow2"
}

cmd_sync() {
  rsync -a --delete --exclude vm/ --exclude .ansible/ --exclude .cache/ \
    -e "ssh ${SSH_OPTS[*]}" "${HERE}/" "${VM_USER}@localhost:${REMOTE_DIR}/"
}

cmd_provision() {
  cmd_sync
  # shellcheck disable=SC2029  # REMOTE_DIR is meant to expand locally
  ssh -t "${SSH_OPTS[@]}" "${VM_USER}@localhost" \
    "cd ${REMOTE_DIR} && { [ -f vars/vars.yml ] || cp vars/vars.example.yml vars/vars.yml; } && ./run.sh"
}

case "${1:-}" in
  fetch) cmd_fetch ;;
  install) cmd_install ;;
  run) cmd_run ;;
  reset) cmd_reset ;;
  sync) cmd_sync ;;
  provision) cmd_provision ;;
  *) usage ;;
esac
```

Run: `chmod +x scripts/vm-test.sh`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/vm-test-dryrun.sh && shellcheck scripts/vm-test.sh tests/*.sh`
Expected: `ok`, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add scripts/vm-test.sh tests/vm-test-dryrun.sh
git commit -m "test: add QEMU harness for a Pop!_OS 24.04 VM

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: [HUMAN-IN-THE-LOOP] Install the base VM and capture COSMIC's real config

This task needs the user at the VM console. The executing agent prints each manual step, waits for the user to confirm, and writes `docs/cosmic-keys.md` from what the user pastes back (or from files copied out over SSH).

**Files:**
- Create: `docs/cosmic-keys.md`

**Interfaces:**
- Produces: `docs/cosmic-keys.md` with, for every setting in the spec's carry-over table: component ID, version directory, key file name, and exact RON content. Also: one captured custom shortcut, the system default file for each key, the preinstalled package list, `pop-desktop`'s dependencies, and yes/no for battery percentage, automatic timezone and per-app notification keys. Tasks 2 (junk list reconcile), 6, 7 and 9 read it.

- [ ] **Step 1: Fetch and install (user)**

Host: `scripts/vm-test.sh fetch && scripts/vm-test.sh install`
User: install Pop!_OS with defaults (no need to encrypt the VM disk), create a user, log in to COSMIC once, then in the VM terminal: `sudo apt-get update && sudo apt-get install -y openssh-server`. Shut the VM down.

- [ ] **Step 2: Boot a capture overlay and snapshot the defaults**

Host: `VM_USER=<vm user> scripts/vm-test.sh run` (leave it running), then in another host terminal:

```bash
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <vm user>@localhost"
$SSH 'cat /etc/os-release; cp -a ~/.config/cosmic /tmp/cosmic-before'
```

- [ ] **Step 3: Change every setting by hand (user, in COSMIC Settings)**

In this order: dark mode on · time applet 12-hour · touchpad tap-to-click off, natural scrolling off, click method "fingers"/clickfinger · mouse natural scrolling off · window controls show minimize and maximize · workspaces "separate per display" and horizontal layout · dock off · auto-tiling off (toggle on then off so the key is written) · battery percentage shown (if offered) · automatic timezone (if offered) · icon theme changed to any non-default theme · add one custom shortcut: Super+E → `cosmic-files`, and one: Shift+Alt+3 → `true` · notifications: look for a per-app toggle.

- [ ] **Step 4: Capture the diff and context**

```bash
$SSH 'diff -ruN /tmp/cosmic-before ~/.config/cosmic' > /tmp/cosmic.diff
$SSH 'find /usr/share/cosmic -type f | sort' > /tmp/cosmic-defaults.txt
$SSH 'for f in $(find /usr/share/cosmic -type f | grep -E "CosmicTheme.Mode|CosmicAppletTime|CosmicComp|CosmicTk|CosmicPanel/|Shortcuts|CosmicNotifications|Battery"); do echo "== $f"; cat "$f"; echo; done' > /tmp/cosmic-default-values.txt
$SSH 'apt-mark showmanual; echo ---; flatpak list --app --columns=application; echo ---; apt-cache depends pop-desktop' > /tmp/pop-packages.txt
```

- [ ] **Step 5: Write `docs/cosmic-keys.md`**

Structure (fill every row from the captured files; write "not found" where a key doesn't exist):

```markdown
# COSMIC config keys — captured from Pop!_OS 24.04

Captured: <date>, /etc/os-release VERSION=<...>, cosmic-comp <apt-cache policy cosmic-comp version>

## Keys used by roles/cosmic

| Behaviour | Path under ~/.config/cosmic | RON value we write |
|---|---|---|
| Dark mode | com.system76.CosmicTheme.Mode/v1/is_dark | `true` |
| 12h clock | ... | ... |
| Touchpad | ... | (full RON struct, verbatim) |
| Mouse | ... | ... |
| Min/max buttons | ... | ... |
| Workspaces per display, horizontal | ... | ... |
| Panel entries without dock | ... | ... |
| Auto-tile off | ... | ... |
| Icon theme | ... | `"<theme>"` |
| Battery % | ... or not found | ... |
| Automatic timezone | ... or not found | ... |
| Per-app notification block | ... or not found | ... |

## Custom shortcuts file (verbatim)

<contents of .../com.system76.CosmicSettings.Shortcuts/v1/custom after Step 3>

Key name used for Shift+Alt+3: <"3" or "numbersign" — as captured>

## Preinstalled packages relevant to common_junk_packages

<intersection of apt-mark showmanual with the current common_junk_packages, plus any other bundled GUI apps>

## pop-desktop Depends

<Depends lines from apt-cache depends pop-desktop>

## Raw diff

<contents of /tmp/cosmic.diff>
```

- [ ] **Step 6: Reconcile the junk list**

Edit `common_junk_packages` in `vars/vars.example.yml`: remove entries that are not installed on Pop, add preinstalled apps the user doesn't want (ask the user about each one, e.g. `geary`, `libreoffice-*`), and remove any entry that appears as a `Depends:` of `pop-desktop` (the Task 2 guard would refuse it anyway). Run `ansible-lint . && yamllint .`.

- [ ] **Step 7: Commit**

```bash
git add docs/cosmic-keys.md vars/vars.example.yml
git commit -m "docs: capture COSMIC config keys and Pop!_OS 24.04 package set

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Leave the VM overlay in place; run `scripts/vm-test.sh reset` before Task 10.

---

### Task 6: `cosmic` role — settings writer, layout and keybindings

**Files:**
- Create: `roles/cosmic/tasks/main.yml`, `roles/cosmic/tasks/settings.yml`, `roles/cosmic/tasks/layout.yml`, `roles/cosmic/tasks/keybindings.yml`, `roles/cosmic/templates/custom-shortcuts.ron.j2`, `molecule/cosmic/molecule.yml`, `molecule/cosmic/converge.yml`, `molecule/cosmic/verify.yml`
- Modify: `vars/vars.example.yml`, `setup_workstation.yml`, `Makefile`, `.circleci/config.yml`

**Interfaces:**
- Consumes: `docs/cosmic-keys.md` (Task 5); `local_user`, `popos_skip_preflight`, `common_is_container`.
- Produces: `roles/cosmic/tasks/settings.yml` — include with `vars: { cosmic_settings_batch: [ {component: str, version: int, key: str, value: str(RON)} ] }`; var `cosmic_config_home`; vars `cosmic_settings`, `cosmic_panel_enabled`, `cosmic_dock_enabled`, `cosmic_autotile`, `cosmic_custom_keybindings` (list of `{name, modifiers: list[str], key: str, command: str}`). Tasks 7 and 8 append imports to `roles/cosmic/tasks/main.yml` and call `settings.yml`.

- [ ] **Step 1: Add the vars, reconciled against `docs/cosmic-keys.md`**

Append to `vars/vars.example.yml`. The values below are provisional; replace each `component`, `version`, `key` and `value` with the captured one from `docs/cosmic-keys.md` (copy multi-line RON structs verbatim from the captured file into a `|-` block). Add battery % / automatic timezone entries only if the doc has them. Change the `key`/`modifiers` spelling in `cosmic_custom_keybindings` to match the captured shortcuts file.

```yaml
# --- COSMIC desktop (roles/cosmic) -----------------------------------------
# COSMIC stores one setting per file: ~/.config/cosmic/<component>/v<version>/<key>,
# holding a RON value. Every entry below was captured from a real Pop!_OS
# 24.04 install — see docs/cosmic-keys.md before changing one.
cosmic_config_home: "/home/{{ local_user }}/.config/cosmic"

cosmic_settings:
  - component: com.system76.CosmicTheme.Mode
    version: 1
    key: is_dark
    value: "true"
  - component: com.system76.CosmicAppletTime
    version: 1
    key: military_time
    value: "false"
  - component: com.system76.CosmicTk
    version: 1
    key: show_minimize
    value: "true"
  - component: com.system76.CosmicTk
    version: 1
    key: show_maximize
    value: "true"
  - component: com.system76.CosmicComp
    version: 1
    key: workspaces
    value: "(workspace_mode: OutputBound, workspace_layout: Horizontal)"
  - component: com.system76.CosmicComp
    version: 1
    key: input_touchpad
    value: |-
      (
          state: Enabled,
          click_method: Some(Clickfinger),
          scroll_config: Some((
              method: Some(TwoFinger),
              natural_scroll: Some(false),
              scroll_button: None,
              scroll_factor: None,
          )),
          tap_config: Some((
              enabled: false,
              button_map: Some(LeftRightMiddle),
              drag: true,
              drag_lock: false,
          )),
      )
  - component: com.system76.CosmicComp
    version: 1
    key: input_default
    value: |-
      (
          state: Enabled,
          scroll_config: Some((
              method: None,
              natural_scroll: Some(false),
              scroll_button: None,
              scroll_factor: None,
          )),
      )

# Layout: top panel on, dock off, auto-tiling off (closest to vanilla GNOME).
cosmic_panel_enabled: true
cosmic_dock_enabled: false
cosmic_autotile: false

# Custom shortcuts. The rendered file REPLACES any custom shortcuts made by
# hand in COSMIC Settings. Modifiers: Super, Ctrl, Alt, Shift. `key` is the
# key name exactly as COSMIC writes it (see docs/cosmic-keys.md).
cosmic_custom_keybindings:
  - name: "1Password Quick Access"
    modifiers: [Ctrl, Shift]
    key: space
    command: "/usr/bin/1password --quick-access"
  - name: "Open File Manager"
    modifiers: [Super]
    key: e
    command: "cosmic-files"
  - name: "Area Screenshot (annotate)"
    modifiers: [Shift, Alt]
    key: "4"
    command: "/home/{{ local_user }}/.local/bin/area-screenshot-annotate"
  - name: "Fullscreen Screenshot (to clipboard)"
    modifiers: [Shift, Alt]
    key: "3"
    command: "/home/{{ local_user }}/.local/bin/fullscreen-screenshot-clip"
```

- [ ] **Step 2: Write the failing test (molecule `cosmic` scenario)**

`molecule/cosmic/molecule.yml`:

```yaml
---
dependency:
  name: galaxy
driver:
  name: podman
platforms:
  - name: cosmic-instance
    image: ubuntu:24.04
    privileged: true
    command: /bin/bash -c "while true; do sleep 30; done"
provisioner:
  name: ansible
  env:
    ANSIBLE_ROLES_PATH: "${MOLECULE_PROJECT_DIRECTORY}/roles"
  playbooks:
    converge: converge.yml
verifier:
  name: ansible
```

`molecule/cosmic/converge.yml`:

```yaml
---
# Converges only the cosmic role against stock Ubuntu 24.04. Its config
# writers are plain file operations, so they can be checked without a desktop;
# anything needing a live session is gated on common_is_container.
- name: Converge the cosmic role
  hosts: all
  become: true
  gather_facts: true
  vars_files:
    - ../../vars/vars.example.yml

  pre_tasks:
    # set_fact outranks vars_files, which would otherwise win over play vars.
    - name: Mark this as a container test
      ansible.builtin.set_fact:
        popos_skip_preflight: true
        common_is_container: true

    - name: Install what the cosmic role expects from common
      ansible.builtin.apt:
        name: [sudo, python3-psutil, git, curl, ca-certificates]
        update_cache: true

    - name: Ensure the test user exists
      ansible.builtin.user:
        name: "{{ local_user }}"
        state: present

  roles:
    - role: cosmic
```

`molecule/cosmic/verify.yml` — update the expected strings to the values from Step 1:

```yaml
---
- name: Verify the cosmic role
  hosts: all
  become: true
  gather_facts: false
  vars_files:
    - ../../vars/vars.example.yml
  vars:
    shortcuts_file: "{{ cosmic_config_home }}/com.system76.CosmicSettings.Shortcuts/v1/custom"
  tasks:
    - name: Read each configured setting
      ansible.builtin.slurp:
        src: "{{ cosmic_config_home }}/{{ item.component }}/v{{ item.version }}/{{ item.key }}"
      loop: "{{ cosmic_settings }}"
      loop_control:
        label: "{{ item.component }}/{{ item.key }}"
      register: verify_settings

    - name: Assert each setting file holds exactly its RON value
      ansible.builtin.assert:
        that: (item.content | b64decode) == item.item.value
        fail_msg: "{{ item.item.key }}: got {{ item.content | b64decode }}"
      loop: "{{ verify_settings.results }}"
      loop_control:
        label: "{{ item.item.key }}"

    - name: Read panel entries and autotile
      ansible.builtin.slurp:
        src: "{{ cosmic_config_home }}/{{ item }}"
      loop:
        - com.system76.CosmicPanel/v1/entries
        - com.system76.CosmicComp/v1/autotile
      register: verify_layout

    - name: Assert panel only, no dock, tiling off
      ansible.builtin.assert:
        that:
          - (verify_layout.results[0].content | b64decode) == '["Panel"]'
          - (verify_layout.results[1].content | b64decode) == 'false'

    - name: Read the custom shortcuts file
      ansible.builtin.slurp:
        src: "{{ shortcuts_file }}"
      register: verify_shortcuts

    - name: Assert the file manager shortcut is rendered
      ansible.builtin.assert:
        that: >-
          (verify_shortcuts.content | b64decode) is search(
          '\(modifiers: \[Super\], key: "e", description: Some\("Open File Manager"\)\): Spawn\("cosmic-files"\),')

    # Review Focus 2: root-owned config means COSMIC can't save GUI changes.
    - name: Find anything under ~/.config/cosmic not owned by the user
      ansible.builtin.command: find /home/{{ local_user }}/.config/cosmic ! -user {{ local_user }}
      register: verify_foreign
      changed_when: false

    - name: Assert everything is owned by the user
      ansible.builtin.assert:
        that: verify_foreign.stdout == ''
        fail_msg: "Not owned by {{ local_user }}: {{ verify_foreign.stdout }}"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `MOLECULE_GLOB=molecule/cosmic/molecule.yml molecule test -s cosmic`
Expected: FAIL in converge — `the role 'cosmic' was not found`.

- [ ] **Step 4: Write `roles/cosmic/tasks/settings.yml`**

```yaml
---
# Generic COSMIC config writer. Callers pass cosmic_settings_batch: a list of
# {component, version, key, value}; each becomes
#   {{ cosmic_config_home }}/<component>/v<version>/<key>
# containing the raw RON value. COSMIC watches these files and applies changes
# live. Runs as local_user so COSMIC can keep writing to its own config.
- name: Ensure COSMIC config directories exist
  ansible.builtin.file:
    path: "{{ cosmic_config_home }}/{{ item }}"
    state: directory
    mode: "0755"
  become: true
  become_user: "{{ local_user }}"
  loop: >-
    {{ cosmic_settings_batch | map(attribute='component')
       | zip(cosmic_settings_batch | map(attribute='version') | map('string'))
       | map('join', '/v') | unique | list }}

- name: Write COSMIC settings
  ansible.builtin.copy:
    dest: "{{ cosmic_config_home }}/{{ item.component }}/v{{ item.version }}/{{ item.key }}"
    # Non-strings (a bool or list a template produced) are JSON-encoded, which
    # is also valid RON for booleans, numbers and lists of strings.
    content: "{{ item.value if item.value is string else (item.value | to_json) }}"
    mode: "0644"
  become: true
  become_user: "{{ local_user }}"
  loop: "{{ cosmic_settings_batch }}"
  loop_control:
    label: "{{ item.component }}/{{ item.key }}"
```

The `mkdir` on `~/.config/cosmic` itself happens as `local_user` too, because `file` creates missing parents as the become user.

- [ ] **Step 5: Write `roles/cosmic/tasks/layout.yml`**

Use the component/key names from `docs/cosmic-keys.md` if they differ.

```yaml
---
# Panel/dock/tiling. COSMIC lists its panels by name in CosmicPanel's
# `entries`; dropping "Dock" removes the dock without touching the panel.
- name: Apply panel, dock and tiling layout
  ansible.builtin.include_tasks: settings.yml
  vars:
    cosmic_settings_batch:
      - component: com.system76.CosmicPanel
        version: 1
        key: entries
        value: >-
          {{ ((['Panel'] if cosmic_panel_enabled | bool else [])
              + (['Dock'] if cosmic_dock_enabled | bool else [])) | to_json }}
      - component: com.system76.CosmicComp
        version: 1
        key: autotile
        value: "{{ cosmic_autotile | bool | string | lower }}"
```

- [ ] **Step 6: Write the keybindings template and task**

`roles/cosmic/templates/custom-shortcuts.ron.j2` — match the captured file's structure from `docs/cosmic-keys.md` exactly (field names, whether `description` exists); this is the provisional shape:

```
{
{% for kb in cosmic_custom_keybindings %}
    (modifiers: [{{ kb.modifiers | join(', ') }}], key: "{{ kb.key }}", description: Some("{{ kb.name | replace('"', '\\"') }}")): Spawn("{{ kb.command | replace('"', '\\"') }}"),
{% endfor %}
}
```

`roles/cosmic/tasks/keybindings.yml`:

```yaml
---
# Custom shortcuts live in a single RON map. Rendering the whole file keeps
# vars authoritative: shortcuts added by hand in COSMIC Settings are replaced
# on the next run (documented in the README).
- name: Ensure the COSMIC shortcuts config directory exists
  ansible.builtin.file:
    path: "{{ cosmic_config_home }}/com.system76.CosmicSettings.Shortcuts/v1"
    state: directory
    mode: "0755"
  become: true
  become_user: "{{ local_user }}"

- name: Render custom shortcuts
  ansible.builtin.template:
    src: custom-shortcuts.ron.j2
    dest: "{{ cosmic_config_home }}/com.system76.CosmicSettings.Shortcuts/v1/custom"
    mode: "0644"
  become: true
  become_user: "{{ local_user }}"
```

- [ ] **Step 7: Write `roles/cosmic/tasks/main.yml`**

```yaml
---
- name: Check for the COSMIC compositor
  ansible.builtin.stat:
    path: /usr/bin/cosmic-comp
  register: cosmic_comp_bin
  tags: [cosmic]

- name: Assert COSMIC is installed
  ansible.builtin.assert:
    that: cosmic_comp_bin.stat.exists
    fail_msg: /usr/bin/cosmic-comp not found — the cosmic role needs the COSMIC desktop (Pop!_OS 24.04).
    quiet: true
  when: not popos_skip_preflight | default(false)
  tags: [cosmic]

- name: Apply COSMIC settings
  ansible.builtin.include_tasks: settings.yml
  vars:
    cosmic_settings_batch: "{{ cosmic_settings }}"
  tags: [cosmic, settings]

- name: Apply panel, dock and tiling layout
  ansible.builtin.import_tasks: layout.yml
  tags: [cosmic, layout]

- name: Apply custom keyboard shortcuts
  ansible.builtin.import_tasks: keybindings.yml
  when: cosmic_custom_keybindings | default([]) | length > 0
  tags: [cosmic, keybindings]
```

- [ ] **Step 8: Wire the role into the playbook, Makefile and CI**

`setup_workstation.yml` roles become:

```yaml
  roles:
    - common
    - third-party
    - role: cosmic
      when: not common_is_container | default(false)
```

`Makefile`: add `test-cosmic` to `.PHONY` and add

```make
# Run Molecule tests for the cosmic role (config writers only)
test-cosmic: check-podman-deps
	@echo "🚀 Running Molecule tests (podman/cosmic)..."
	$(MOLECULE_ENV) MOLECULE_GLOB="molecule/cosmic/molecule.yml" molecule test -s cosmic
	@echo "✅ Molecule cosmic tests completed successfully."
```

`.circleci/config.yml`, `molecule-syntax` job: change the command to `molecule syntax -s default && MOLECULE_GLOB=molecule/cosmic/molecule.yml molecule syntax -s cosmic`.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `make test-cosmic && ansible-playbook --syntax-check setup_workstation.yml && ansible-lint . && yamllint .`
Expected: converge ok, idempotence ok (`changed=0` on second converge), verify all asserts ok; lint passes.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(cosmic): data-driven COSMIC settings, layout and custom shortcuts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `cosmic` role — dark mode across toolkits and Colloid icons

**Files:**
- Create: `roles/cosmic/tasks/theme.yml`, `roles/cosmic/tasks/icon-theme.yml`, `roles/cosmic/files/colloid-icons/{google-keep,google-tasks,google-messages,cider}.svg`
- Modify: `roles/cosmic/tasks/main.yml`, `vars/vars.example.yml`, `molecule/cosmic/verify.yml`

**Interfaces:**
- Consumes: `roles/cosmic/tasks/settings.yml` (`cosmic_settings_batch`); `electron_apps_slugs` (Task 3).
- Produces: vars `install_colloid_icons`, `cosmic_icon_theme`, `colloid_*`, `cosmic_cursor_size`, `cosmic_darkmode_candidate_pkgs`, `cosmic_darkmode_env`.

- [ ] **Step 1: Add vars**

Append to the COSMIC section of `vars/vars.example.yml` (icon-theme component/key from `docs/cosmic-keys.md`):

```yaml
# Cursor size (px) for the GTK settings.ini fallbacks.
cosmic_cursor_size: 24

# Colloid icon theme (https://github.com/vinceliuice/Colloid-icon-theme),
# installed per-user and selected in COSMIC. false = keep Pop's default icons.
install_colloid_icons: true
cosmic_icon_theme: Colloid-Dark
colloid_icon_repo: https://github.com/vinceliuice/Colloid-icon-theme.git
colloid_icon_version: main
colloid_icon_src: "/home/{{ local_user }}/.local/src/Colloid-icon-theme"
colloid_icon_dest: "/home/{{ local_user }}/.local/share/icons"
# Extra install.sh flags, e.g. "-t purple -s nord -b". Empty = default blue.
colloid_icon_install_args: ""
# Icons Colloid has nothing for; sourced from roles/cosmic/files/colloid-icons/.
# Keep in step with electron_apps_slugs.
colloid_extra_icons:
  - google-keep.svg
  - google-tasks.svg
  - google-messages.svg
  - cider.svg
# Second names for icons already in the theme (symlinked).
colloid_icon_aliases:
  - name: messenger.svg
    target: fbmessenger.svg
  - name: sh.cider.Cider.svg
    target: cider.svg

# Dark-mode integration packages, probed with apt-cache; whichever this
# release ships get installed, the rest are reported and skipped.
cosmic_darkmode_candidate_pkgs:
  - adw-gtk3
  - gnome-themes-extra
  - qt5-gtk-platformtheme
  - qt6-gtk-platformtheme
  - adwaita-qt
  - adwaita-qt6

# Environment so non-GTK toolkits follow dark mode. Written to /etc/environment
# and ~/.config/environment.d; takes effect at next login.
cosmic_darkmode_env:
  QT_QPA_PLATFORMTHEME: gtk3
  # Only takes effect if an adwaita Qt decoration plugin is installed; COSMIC
  # also offers server-side decorations, which Qt uses when the plugin is absent.
  QT_WAYLAND_DECORATION: adwaita
  ELECTRON_OZONE_PLATFORM_HINT: auto
```

- [ ] **Step 2: Write the failing test**

Append to `molecule/cosmic/verify.yml`:

```yaml
    - name: Read the COSMIC icon theme setting
      ansible.builtin.slurp:
        src: "{{ cosmic_config_home }}/com.system76.CosmicTk/v1/icon_theme"
      register: verify_icon_theme

    - name: Assert Colloid is selected
      ansible.builtin.assert:
        that: (verify_icon_theme.content | b64decode) == '"' ~ cosmic_icon_theme ~ '"'

    - name: Check theme, extras and aliases are on disk
      ansible.builtin.stat:
        path: "{{ colloid_icon_dest }}/{{ item }}"
      loop:
        - "{{ cosmic_icon_theme }}/index.theme"
        - Colloid-Light/apps/scalable/google-keep.svg
        - Colloid-Light/apps/scalable/sh.cider.Cider.svg
      register: verify_icons

    - name: Assert icons are installed
      ansible.builtin.assert:
        that: item.stat.exists
        fail_msg: "missing {{ item.item }}"
      loop: "{{ verify_icons.results }}"
      loop_control:
        label: "{{ item.item }}"

    - name: Read GTK3 settings.ini and environment.d
      ansible.builtin.slurp:
        src: "/home/{{ local_user }}/{{ item }}"
      loop:
        - .config/gtk-3.0/settings.ini
        - .config/environment.d/90-dark-mode.conf
      register: verify_dark

    - name: Assert GTK3 and Qt are pointed at dark
      ansible.builtin.assert:
        that:
          - (verify_dark.results[0].content | b64decode) is search('gtk-theme-name = adw-gtk3-dark')
          - (verify_dark.results[1].content | b64decode) is search('QT_QPA_PLATFORMTHEME=gtk3')
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make test-cosmic`
Expected: verify FAILS at `Read the COSMIC icon theme setting` (file not found).

- [ ] **Step 4: Copy the extra icons from Fedora**

```bash
mkdir -p roles/cosmic/files/colloid-icons
cp "$FEDORA"/roles/gnome/files/colloid-icons/{google-keep,google-tasks,google-messages,cider}.svg roles/cosmic/files/colloid-icons/
```

- [ ] **Step 5: Write `roles/cosmic/tasks/icon-theme.yml`**

```bash
cp "$FEDORA/roles/gnome/tasks/icon-theme.yml" roles/cosmic/tasks/icon-theme.yml
```

Then edit the copy:
- First task: `ansible.builtin.dnf` → `ansible.builtin.apt`; keep the package names `git` and `gtk-update-icon-cache` (same names on Ubuntu).
- Replace every `gnome_icon_theme` with `cosmic_icon_theme`, every registered var prefix `gnome_colloid_` with `cosmic_colloid_`, every `tags: [gnome, icon-theme]` with `tags: [cosmic, icon-theme]`, and `roles/gnome/files/colloid-icons/` in the assert message with `roles/cosmic/files/colloid-icons/`.
- In the header comment, change "the dock shows one un-themed tile" to "the launcher shows one un-themed icon", and drop "TIDAL" from the list of extras.

Append the COSMIC selection at the end of the file:

```yaml
- name: Select the icon theme in COSMIC
  ansible.builtin.include_tasks: settings.yml
  vars:
    cosmic_settings_batch:
      - component: com.system76.CosmicTk
        version: 1
        key: icon_theme
        value: '"{{ cosmic_icon_theme }}"'
  tags: [cosmic, icon-theme]
```

- [ ] **Step 6: Write `roles/cosmic/tasks/theme.yml`**

```yaml
---
# COSMIC's own dark mode (CosmicTheme.Mode/is_dark, set via cosmic_settings)
# reaches COSMIC apps and libadwaita apps through the settings portal.
# Everything else needs help:
#   - GTK3 apps read gtk-theme-name; adw-gtk3-dark is a theme whose CSS is dark
#     unconditionally, so CSS-reading consumers (libqgtk3, CEF) see dark too.
#   - GTK2 apps read ~/.gtkrc-2.0.
#   - Qt apps take their palette from the GTK3 theme via QT_QPA_PLATFORMTHEME=gtk3.
#   - Electron apps run under XWayland by default and draw a light titlebar;
#     ELECTRON_OZONE_PLATFORM_HINT=auto runs them natively on Wayland.
# The candidate-package probe exists because availability changes between
# releases; install what this release ships, report the rest.
- name: Probe which dark-mode integration packages this release ships
  ansible.builtin.command: "apt-cache show --no-all-versions {{ item }}"
  loop: "{{ cosmic_darkmode_candidate_pkgs }}"
  register: cosmic_darkmode_pkg_probe
  changed_when: false
  failed_when: false
  tags: [cosmic, dark-mode]

- name: Partition dark-mode packages into available vs missing
  ansible.builtin.set_fact:
    cosmic_darkmode_pkgs_available: "{{ cosmic_darkmode_pkg_probe.results | selectattr('rc', 'equalto', 0) | map(attribute='item') | list }}"
    cosmic_darkmode_pkgs_missing: "{{ cosmic_darkmode_pkg_probe.results | rejectattr('rc', 'equalto', 0) | map(attribute='item') | list }}"
  tags: [cosmic, dark-mode]

- name: Note dark-mode packages not shipped by this release
  ansible.builtin.debug:
    msg: "Skipping theming packages not in this release's repos: {{ cosmic_darkmode_pkgs_missing | join(', ') }}"
  when: cosmic_darkmode_pkgs_missing | length > 0
  tags: [cosmic, dark-mode]

- name: Install available dark-mode integration packages
  ansible.builtin.apt:
    name: "{{ cosmic_darkmode_pkgs_available }}"
    state: present
  become: true
  when: cosmic_darkmode_pkgs_available | length > 0
  tags: [cosmic, dark-mode]

- name: Ensure GTK and environment.d config directories exist
  ansible.builtin.file:
    path: "/home/{{ local_user }}/{{ item }}"
    state: directory
    mode: "0755"
  become: true
  become_user: "{{ local_user }}"
  loop:
    - .config/gtk-3.0
    - .config/gtk-4.0
    - .config/environment.d
  tags: [cosmic, dark-mode]

- name: Configure GTK2 dark theme (~/.gtkrc-2.0)
  ansible.builtin.copy:
    dest: "/home/{{ local_user }}/.gtkrc-2.0"
    mode: "0644"
    content: |
      # {{ ansible_managed }}
      gtk-theme-name = "adw-gtk3-dark"
      gtk-icon-theme-name = "{{ cosmic_icon_theme if install_colloid_icons | default(false) else 'Adwaita' }}"
      gtk-cursor-theme-name = "Adwaita"
      gtk-cursor-theme-size = {{ cosmic_cursor_size }}
  become: true
  become_user: "{{ local_user }}"
  tags: [cosmic, dark-mode]

- name: Configure GTK3 dark theme (~/.config/gtk-3.0/settings.ini)
  ansible.builtin.copy:
    dest: "/home/{{ local_user }}/.config/gtk-3.0/settings.ini"
    mode: "0644"
    content: |
      # {{ ansible_managed }}
      [Settings]
      gtk-application-prefer-dark-theme = 1
      gtk-theme-name = adw-gtk3-dark
      gtk-icon-theme-name = {{ cosmic_icon_theme if install_colloid_icons | default(false) else 'Adwaita' }}
      gtk-cursor-theme-name = Adwaita
      gtk-cursor-theme-size = {{ cosmic_cursor_size }}
  become: true
  become_user: "{{ local_user }}"
  tags: [cosmic, dark-mode]

- name: Configure GTK4 dark theme preference (~/.config/gtk-4.0/settings.ini)
  ansible.builtin.copy:
    dest: "/home/{{ local_user }}/.config/gtk-4.0/settings.ini"
    mode: "0644"
    content: |
      # {{ ansible_managed }}
      [Settings]
      gtk-application-prefer-dark-theme = 1
      gtk-icon-theme-name = {{ cosmic_icon_theme if install_colloid_icons | default(false) else 'Adwaita' }}
      gtk-cursor-theme-name = Adwaita
      gtk-cursor-theme-size = {{ cosmic_cursor_size }}
  become: true
  become_user: "{{ local_user }}"
  tags: [cosmic, dark-mode]

- name: Route Qt and Electron apps at dark-aware integrations (system)
  ansible.builtin.lineinfile:
    path: /etc/environment
    regexp: "^{{ item.key }}="
    line: "{{ item.key }}={{ item.value }}"
    state: present
    create: true
    mode: "0644"
  become: true
  loop: "{{ cosmic_darkmode_env | dict2items }}"
  loop_control:
    label: "{{ item.key }}"
  tags: [cosmic, dark-mode]

- name: Route Qt and Electron apps at dark-aware integrations (user session)
  ansible.builtin.copy:
    dest: "/home/{{ local_user }}/.config/environment.d/90-dark-mode.conf"
    mode: "0644"
    content: |
      # {{ ansible_managed }}
      {% for key, value in cosmic_darkmode_env | dictsort %}
      {{ key }}={{ value }}
      {% endfor %}
  become: true
  become_user: "{{ local_user }}"
  tags: [cosmic, dark-mode]

# GTK3 apps on Wayland and the GNOME portal backends still read these
# gsettings keys. Needs a dconf database, so not in containers.
- name: Point GNOME interface settings at dark
  community.general.dconf:
    key: "{{ item.k }}"
    value: "{{ item.v }}"
    state: present
  become: true
  become_user: "{{ local_user }}"
  loop:
    - { k: /org/gnome/desktop/interface/color-scheme, v: "'prefer-dark'" }
    - { k: /org/gnome/desktop/interface/gtk-theme, v: "'adw-gtk3-dark'" }
    - k: /org/gnome/desktop/interface/icon-theme
      v: "'{{ cosmic_icon_theme if install_colloid_icons | default(false) else 'Adwaita' }}'"
  when: not common_is_container | default(false)
  tags: [cosmic, dark-mode]
```

- [ ] **Step 7: Wire into `roles/cosmic/tasks/main.yml`** (append)

```yaml
- name: Dark mode across GTK2/3/4, Qt and Electron
  ansible.builtin.import_tasks: theme.yml
  tags: [cosmic, dark-mode]

- name: Colloid icon theme
  ansible.builtin.import_tasks: icon-theme.yml
  when: install_colloid_icons | default(false)
  tags: [cosmic, icon-theme]
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `make test-cosmic && ansible-lint . && yamllint .`
Expected: converge, idempotence and verify pass (Colloid install takes a few minutes on first converge).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(cosmic): dark mode across toolkits and Colloid icon theme

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `cosmic` role — screenshot helpers and Satty

**Files:**
- Create: `roles/cosmic/tasks/screenshots.yml`, `roles/cosmic/files/{portal-screenshot-clip,area-screenshot-clip,fullscreen-screenshot-clip,area-screenshot-annotate}`
- Modify: `roles/cosmic/tasks/main.yml`, `vars/vars.example.yml`, `molecule/cosmic/verify.yml`

**Interfaces:**
- Consumes: `cosmic_custom_keybindings` commands `~/.local/bin/area-screenshot-annotate` and `~/.local/bin/fullscreen-screenshot-clip` (Task 6).
- Produces: vars `satty_version`, `satty_sha256`; `/usr/local/bin/satty`; four scripts in `~/.local/bin`.

- [ ] **Step 1: Add vars**

Append to `vars/vars.example.yml`:

```yaml
# Satty (github.com/gabm/Satty) — Wayland screenshot annotator used by the
# Shift+Alt+4 shortcut, installed from the upstream x86_64 tarball. Bump both
# together: sha256 of satty-x86_64-unknown-linux-gnu.tar.gz on the release page.
satty_version: "0.22.0"
satty_sha256: "eb7a028c4a5ce331c2f355add8e2b807a7d697fe4495f7e1965786a4f6bcd5b8"
```

- [ ] **Step 2: Write the failing test**

Append to `molecule/cosmic/verify.yml`:

```yaml
    - name: Check the screenshot helpers are installed and executable
      ansible.builtin.stat:
        path: "/home/{{ local_user }}/.local/bin/{{ item }}"
      loop:
        - portal-screenshot-clip
        - area-screenshot-clip
        - fullscreen-screenshot-clip
        - area-screenshot-annotate
      register: verify_helpers

    - name: Assert helpers exist, are executable and user-owned
      ansible.builtin.assert:
        that:
          - item.stat.exists
          - item.stat.executable
          - item.stat.pw_name == local_user
        fail_msg: "{{ item.item }}"
      loop: "{{ verify_helpers.results }}"
      loop_control:
        label: "{{ item.item }}"

    # Proves the upstream binary links against this release's GTK4/libadwaita.
    - name: Run satty --version
      ansible.builtin.command: /usr/local/bin/satty --version
      register: verify_satty
      changed_when: false

    - name: Assert the pinned Satty is installed
      ansible.builtin.assert:
        that: verify_satty.stdout is search('satty ' ~ satty_version)
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make test-cosmic`
Expected: verify FAILS at `Assert helpers exist...` (`item.stat.exists` false).

- [ ] **Step 4: Copy the helper scripts from Fedora**

```bash
for f in portal-screenshot-clip area-screenshot-clip fullscreen-screenshot-clip area-screenshot-annotate; do
  cp "$FEDORA/roles/gnome/files/$f" "roles/cosmic/files/$f"
done
```

In `portal-screenshot-clip` and `area-screenshot-annotate`, change the docstring's first explanatory paragraph to:

```
Captures via the xdg-desktop-portal Screenshot interface, which
xdg-desktop-portal-cosmic implements on COSMIC (interactive=True shows
COSMIC's own region/window/screen picker).
```

and the `--interactive` help line in `portal-screenshot-clip` to `show COSMIC's area/window/screen picker (default)`. Leave the code unchanged.

- [ ] **Step 5: Write `roles/cosmic/tasks/screenshots.yml`**

```yaml
---
# Screenshot helpers bound by cosmic_custom_keybindings. Capture goes through
# the xdg-desktop-portal Screenshot interface (xdg-desktop-portal-cosmic);
# wl-copy puts the PNG on the Wayland clipboard; Satty annotates area grabs.
- name: Install screenshot helper dependencies
  ansible.builtin.apt:
    name:
      - python3-gi                 # PyGObject (Gio/GLib) for the portal D-Bus call
      - wl-clipboard               # wl-copy
      - libgtk-4-1                 # Satty runtime
      - libadwaita-1-0             # Satty runtime
    state: present
  become: true
  tags: [cosmic, screenshot]

# Pop!_OS ships this; listed separately because the ubuntu:24.04 test
# container's repos don't carry it.
- name: Install the COSMIC portal backend
  ansible.builtin.apt:
    name: xdg-desktop-portal-cosmic
    state: present
  become: true
  when: not common_is_container | default(false)
  tags: [cosmic, screenshot]

- name: Check installed Satty version
  ansible.builtin.command: /usr/local/bin/satty --version
  register: cosmic_satty_installed
  failed_when: false
  changed_when: false
  check_mode: false
  tags: [cosmic, screenshot, satty]

- name: Download Satty release tarball
  ansible.builtin.get_url:
    url: "https://github.com/gabm/Satty/releases/download/v{{ satty_version }}/satty-x86_64-unknown-linux-gnu.tar.gz"
    dest: "/tmp/satty-{{ satty_version }}.tar.gz"
    checksum: "sha256:{{ satty_sha256 }}"
    mode: "0644"
  when: cosmic_satty_installed.stdout | default('') is not search('satty ' ~ satty_version)
  tags: [cosmic, screenshot, satty]

- name: Install Satty binary to /usr/local/bin
  ansible.builtin.unarchive:
    src: "/tmp/satty-{{ satty_version }}.tar.gz"
    dest: /usr/local/bin/
    include: [satty]
    remote_src: true
    owner: root
    group: root
    mode: "0755"
  become: true
  when: cosmic_satty_installed.stdout | default('') is not search('satty ' ~ satty_version)
  tags: [cosmic, screenshot, satty]

- name: Ensure ~/.local/bin and ~/Pictures/Screenshots exist
  ansible.builtin.file:
    path: "/home/{{ local_user }}/{{ item }}"
    state: directory
    mode: "0755"
  become: true
  become_user: "{{ local_user }}"
  loop:
    - .local/bin
    - Pictures/Screenshots
  tags: [cosmic, screenshot]

- name: Install screenshot helper scripts
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/home/{{ local_user }}/.local/bin/{{ item }}"
    mode: "0755"
  become: true
  become_user: "{{ local_user }}"
  loop:
    - portal-screenshot-clip      # shared core: drives the portal Screenshot call
    - area-screenshot-clip        # wrapper -> core --interactive
    - fullscreen-screenshot-clip  # wrapper -> core --fullscreen
    - area-screenshot-annotate    # capture -> pipe into Satty for annotation
  tags: [cosmic, screenshot]
```

Append to `roles/cosmic/tasks/main.yml`:

```yaml
- name: Screenshot helpers and Satty
  ansible.builtin.import_tasks: screenshots.yml
  tags: [cosmic, screenshot]
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test-cosmic && ansible-lint . && yamllint .`
Expected: all pass, including `Assert the pinned Satty is installed`.

If `satty --version` fails with a missing library or `version 'LIBADWAITA_1_x' not found`, the pinned release needs a newer GTK/libadwaita than Ubuntu 24.04 has. Walk back through https://github.com/gabm/Satty/releases one release at a time: set `satty_version`, get the hash with `curl -fsSL https://github.com/gabm/Satty/releases/download/v<ver>/satty-x86_64-unknown-linux-gnu.tar.gz | shasum -a 256`, set `satty_sha256`, re-run, until verify passes. Note the chosen version and the reason in the `satty_version` comment.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(cosmic): portal screenshot helpers and Satty annotation

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Notifications decision, README, CHANGELOG

**Files:**
- Create: `roles/cosmic/tasks/notifications.yml` (only if `docs/cosmic-keys.md` found a per-app notification key)
- Modify: `README.md`, `CHANGELOG.md`, `vars/vars.example.yml`, `roles/cosmic/tasks/main.yml`, `molecule/cosmic/verify.yml` (if notifications.yml is created)

**Interfaces:**
- Consumes: `docs/cosmic-keys.md` "Per-app notification block" row.

- [ ] **Step 1: Decide notifications from the capture**

If `docs/cosmic-keys.md` says "not found" for per-app notification blocking: create nothing; the README "Not on COSMIC" section below lists it. Skip to Step 3.

If a key exists: add to `vars/vars.example.yml`

```yaml
# Terminal apps whose desktop notifications are suppressed.
cosmic_notification_blocked_apps:
  - Alacritty
  - com.system76.CosmicTerm
```

then append a verify assert to `molecule/cosmic/verify.yml` that slurps the captured file path and asserts both app IDs appear in it, run `make test-cosmic` and see it fail, write `roles/cosmic/tasks/notifications.yml` that includes `settings.yml` with one batch entry whose `value` renders the captured RON shape from `cosmic_notification_blocked_apps`, import it from `main.yml` with `tags: [cosmic, notifications]`, and re-run until verify passes.

- [ ] **Step 2: (only if Step 1 added code) Commit**

```bash
git add -A
git commit -m "feat(cosmic): suppress notifications from terminal apps

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Rewrite `README.md`**

Replace the whole file with the following. Fill the "Not on COSMIC" list from the spec's Dropped section plus anything Tasks 5–9 found missing (battery %, automatic timezone, notifications).

````markdown
# Pop!_OS Workstation Base

Ansible playbook that sets up a **Pop!_OS 24.04 LTS (COSMIC)** laptop for
development and daily use. Sibling of
[ansible-ubuntu-workstation-base](https://github.com/mtharpe/ansible-ubuntu-workstation-base)
and [ansible-fedora-workstation-base](https://github.com/mtharpe/ansible-fedora-workstation-base):
same tools, apps and shell setup, with the GNOME pieces translated to COSMIC.

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

`run.sh` installs Ansible via pipx, adds a temporary passwordless-sudo drop-in, retries the playbook until it succeeds, then removes the drop-in.

## Customising COSMIC

COSMIC stores one setting per file under `~/.config/cosmic/<component>/v<N>/<key>`.
`cosmic_settings` in `vars/vars.yml` lists the files this playbook writes;
`docs/cosmic-keys.md` records where each value came from. To add a setting:
change it in COSMIC Settings, find the file that changed
(`find ~/.config/cosmic -newer /tmp/marker` after `touch /tmp/marker`), and copy
its component, version, key and contents into `cosmic_settings`.

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

## Feature flags

See `vars/vars.example.yml` — every `install_*` flag is documented inline.

## Testing

- `make test` — Molecule converge + idempotence + verify of `common` and `third-party` on an Ubuntu 24.04 container
- `make test-cosmic` — Molecule for the `cosmic` role's config writers, theming and screenshot helpers
- `tests/no-ubuntu-leftovers.sh`, `tests/vm-test-dryrun.sh`, `ANSIBLE_ROLES_PATH=roles ansible-playbook tests/preflight.yml` (must fail on a non-Pop host)
- Full run on a Pop!_OS VM with `scripts/vm-test.sh` (`fetch`, `install`, `run`, `provision`, `reset`). Needs QEMU; fast on a Linux x86_64 host with KVM, very slow under emulation on Apple Silicon.

## Linting and CI

CircleCI runs ansible-lint, yamllint, `ansible-playbook --syntax-check`, Molecule syntax for both scenarios, and shellcheck.

## License

MIT
````

- [ ] **Step 4: Update `CHANGELOG.md`**

Insert at the top, under `# Changelog`:

```markdown
## Unreleased (Pop!_OS port)
- Fork of ansible-ubuntu-workstation-base for Pop!_OS 24.04 with COSMIC
- Replace `roles/gnome` with `roles/cosmic` (RON config writer, panel/dock/tiling layout, custom shortcuts, dark mode, Colloid icons, portal screenshots + Satty)
- Add Twingate (apt), Cider (flatpak) and electron-apps from the Fedora playbook
- Add Pop!_OS preflight check and a junk-app purge that refuses to remove pop-desktop/COSMIC
- Remove WSL playbook, Multipass, snap launcher shadowing and GNOME extensions
- Add `scripts/vm-test.sh` QEMU harness and `molecule/cosmic` scenario
```

- [ ] **Step 5: Run checks and commit**

Run: `ansible-lint . && yamllint . && tests/no-ubuntu-leftovers.sh`
Expected: pass.

```bash
git add README.md CHANGELOG.md
git commit -m "docs: README and changelog for the Pop!_OS COSMIC playbook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: [HUMAN-IN-THE-LOOP] Acceptance run on the Pop!_OS VM

The user drives the VM display; the executing agent runs host commands, lists what to check, and records results. Any failure found here goes back through superpowers:systematic-debugging, then a fix commit, then this task re-runs from Step 1.

**Files:**
- Create: `docs/acceptance-2026-10-11.md` (results log; rename with the actual date)

- [ ] **Step 1: Fresh overlay**

Host: `scripts/vm-test.sh reset && VM_USER=<vm user> scripts/vm-test.sh run` (leave it running).

- [ ] **Step 2: Provision over SSH (Review Focus 3, 5)**

Host: `VM_USER=<vm user> scripts/vm-test.sh provision`
Expected: preflight passes (`Assert the host is Pop!_OS 24.04` ok), play recap `failed=0`. Enter the sudo password when prompted.

- [ ] **Step 3: Idempotence**

Host: `VM_USER=<vm user> scripts/vm-test.sh provision`
Expected: play recap `changed=0`. Any task reporting `changed` on the second run is a bug: fix it (usually a missing `creates:`/`changed_when:`), commit, and repeat from Step 1.

- [ ] **Step 4: Visual and functional checks (user, after logging out and back in)**

Record pass/fail for each in `docs/acceptance-<date>.md`:
- Dark theme; Colloid icons in the launcher; top panel present; no dock; new windows float (no tiling)
- Clock shows 12-hour time
- Touchpad: tap does not click; two-finger click is right-click; scrolling not natural. Mouse scrolling not natural.
- Windows show minimize + maximize + close
- Super+E opens COSMIC Files; Ctrl+Shift+Space opens 1Password Quick Access
- Shift+Alt+3: screenshot on clipboard (paste into any app); Shift+Alt+4: region picker, then Satty opens
- Launch: Chrome, Slack, VS Code, Zoom, 1Password, Twingate (`twingate status`), Cider, Alacritty, each electron app (Gmail, Calendar, Tasks, Keep, Messages, Messenger)
- A Qt app renders dark (e.g. `sudo apt install -y qt5ct && qt5ct` or any Qt app installed by the run) and an Electron app (Slack) has a dark titlebar
- `firefox`, `libreoffice` gone; `apt-mark showmanual | grep pop-desktop` still lists pop-desktop
- `find ~/.config/cosmic ! -user $USER` prints nothing

- [ ] **Step 5: Hand-edit behaviour (Review Focus 4)**

User: in COSMIC Settings turn dark mode off and add a custom shortcut by hand. Host: `scripts/vm-test.sh provision`.
Expected: dark mode back on; hand-made shortcut gone; listed shortcuts present. Record the result.

- [ ] **Step 6: auto-cpufreq guard**

In the VM: `cd ~/ansible-popos-workstation-base && sed -i 's/^install_autocpu: false/install_autocpu: true/' vars/vars.yml && ./run.sh` — interrupt with Ctrl+C after the first failure.
Expected: fails at `Refuse auto-cpufreq alongside system76-power` with the system76-power message. Restore: `sed -i 's/^install_autocpu: true/install_autocpu: false/' vars/vars.yml`.

- [ ] **Step 7: Commit the acceptance log**

```bash
git add docs/acceptance-*.md
git commit -m "test: Pop!_OS 24.04 VM acceptance results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
