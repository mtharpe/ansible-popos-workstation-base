#!/bin/bash
set -euo pipefail

if ! command -v pipx >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y pipx
fi

export PATH="${HOME}/.local/bin:${PATH}"

# Ansible is the only thing run.sh bootstraps — it's required to run the
# playbook itself. Dev/test tooling (ansible-lint, yamllint, molecule) is
# intentionally not installed here; that belongs in a separate dev-tools
# play, not the workstation provisioning bootstrap.
if ! command -v ansible >/dev/null 2>&1; then
  pipx install --include-deps ansible
fi

# Ubuntu's apt-shipped ansible.posix is too old and emits a `to_native`
# deprecation on every sysctl task. Pull the pinned versions from Galaxy.
ansible-galaxy collection install -r requirements.yml --upgrade

SUDOERS_DROPIN="/etc/sudoers.d/${USER}"
if [ ! -f "${SUDOERS_DROPIN}" ]; then
  echo "${USER} ALL=(ALL) NOPASSWD: ALL" | sudo tee -a "${SUDOERS_DROPIN}"
fi
# Remove the passwordless-sudo drop-in however this script exits.
trap 'sudo rm -f "${SUDOERS_DROPIN}"' EXIT

# Retry a few times for flaky mirrors, but stop: the playbook also fails on
# purpose (wrong host, a junk purge that would remove the desktop), and those
# don't fix themselves.
RUN_RETRIES="${RUN_RETRIES:-3}"
RUN_RETRY_DELAY="${RUN_RETRY_DELAY:-10}"
attempt=1
until ansible-playbook --extra-vars "local_user=${USER}" setup_workstation.yml; do
  if [ "${attempt}" -ge "${RUN_RETRIES}" ]; then
    echo "Ansible run failed ${attempt} times; giving up. Fix the error above and re-run." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "Ansible run disrupted, retrying in ${RUN_RETRY_DELAY} seconds (attempt ${attempt}/${RUN_RETRIES})..."
  sleep "${RUN_RETRY_DELAY}"
done
