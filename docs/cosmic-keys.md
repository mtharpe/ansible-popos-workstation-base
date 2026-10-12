# COSMIC config keys — Pop!_OS 24.04

> **Status: PROVISIONAL — not yet captured from a real system.**
> Every row below is the value the playbook currently writes, taken from
> COSMIC's source conventions rather than from a running Pop!_OS 24.04 box.
> Replace each value with the captured one (procedure at the bottom), then
> update `cosmic_settings` / `cosmic_custom_keybindings` in
> `vars/vars.example.yml`, the template
> `roles/cosmic/templates/custom-shortcuts.ron.j2`, and the expected strings in
> `molecule/cosmic/verify.yml` to match. Delete this banner when done.

## Keys used by roles/cosmic

| Behaviour | Path under ~/.config/cosmic | RON value we write | Captured? |
|---|---|---|---|
| Dark mode | `com.system76.CosmicTheme.Mode/v1/is_dark` | `true` | no |
| 12h clock | `com.system76.CosmicAppletTime/v1/military_time` | `false` | no |
| Touchpad | `com.system76.CosmicComp/v1/input_touchpad` | struct, see `vars/vars.example.yml` | no |
| Mouse | `com.system76.CosmicComp/v1/input_default` | struct, see `vars/vars.example.yml` | no |
| Minimize button | `com.system76.CosmicTk/v1/show_minimize` | `true` | no |
| Maximize button | `com.system76.CosmicTk/v1/show_maximize` | `true` | no |
| Workspaces per display, horizontal | `com.system76.CosmicComp/v1/workspaces` | `(workspace_mode: OutputBound, workspace_layout: Horizontal)` | no |
| Panel entries without dock | `com.system76.CosmicPanel/v1/entries` | `["Panel"]` | no |
| Auto-tile off | `com.system76.CosmicComp/v1/autotile` | `false` | no |
| Icon theme | `com.system76.CosmicTk/v1/icon_theme` | `"Colloid-Dark"` | no |
| Battery % | unknown | not written | no |
| Automatic timezone | unknown | not written | no |
| Per-app notification block | unknown | not written (listed under "Not on COSMIC") | no |

## Custom shortcuts file (provisional shape)

`com.system76.CosmicSettings.Shortcuts/v1/custom`:

```
{
    (modifiers: [Super], key: "e", description: Some("Open File Manager")): Spawn("cosmic-files"),
}
```

Key name used for Shift+Alt+3: `"3"` (unverified; COSMIC may record the
shifted keysym, e.g. `"numbersign"`).

## Preinstalled packages / pop-desktop Depends

Not yet captured. Until then `common_junk_packages` is the Ubuntu list minus
GNOME-only apps, and the purge is protected by the simulation guard in
`roles/common/tasks/junk-apps.yml`.

## Capture procedure

Plan Task 5 (`docs/superpowers/plans/2026-10-11-popos-cosmic-playbook.md`):

1. `scripts/vm-test.sh fetch && scripts/vm-test.sh install` — install Pop!_OS,
   log in once, `sudo apt-get install -y openssh-server`, shut down.
2. `VM_USER=<user> scripts/vm-test.sh run`; then over SSH:
   `cp -a ~/.config/cosmic /tmp/cosmic-before`.
3. Change every setting in the table above by hand in COSMIC Settings, plus
   one custom shortcut (Super+E → `cosmic-files`, Shift+Alt+3 → `true`).
4. `diff -ruN /tmp/cosmic-before ~/.config/cosmic`, `find /usr/share/cosmic -type f`,
   `apt-mark showmanual`, `flatpak list --app`, `apt-cache depends pop-desktop`.
5. Fill this file from the output and reconcile the files listed in the banner.
