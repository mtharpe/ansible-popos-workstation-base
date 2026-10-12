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
