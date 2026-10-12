#!/usr/bin/env bash
# Tag filtering and an emptied shortcut list must still reach the files.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
log="${tmp}/ansible.log"
cfg="${tmp}/cosmic"

play() {
  ANSIBLE_ROLES_PATH=roles ansible-playbook tests/cosmic-local.yml \
    -e "cosmic_config_home=${cfg}" -e "local_user=${USER}" -e ansible_become=false \
    "$@" >"${log}" 2>&1 || { cat "${log}"; echo "ansible-playbook failed"; exit 1; }
}

# --tags settings must still write the settings files.
play --tags settings
dark="${cfg}/com.system76.CosmicTheme.Mode/v1/is_dark"
[ "$(cat "${dark}" 2>/dev/null)" = "true" ] || { echo "--tags settings wrote nothing to ${dark}"; exit 1; }

# --tags layout must still write the panel entries.
play --tags layout
[ "$(cat "${cfg}/com.system76.CosmicPanel/v1/entries" 2>/dev/null)" = '["Panel"]' ] \
  || { echo "--tags layout wrote no panel entries"; exit 1; }

# An emptied shortcut list must replace a previously rendered file.
shortcuts="${cfg}/com.system76.CosmicSettings.Shortcuts/v1/custom"
mkdir -p "$(dirname "${shortcuts}")"
echo 'stale-shortcut' >"${shortcuts}"
play --tags keybindings -e '{"cosmic_custom_keybindings": []}'
if grep -q stale-shortcut "${shortcuts}"; then
  echo "emptied cosmic_custom_keybindings left stale shortcuts behind"; exit 1
fi
echo ok
