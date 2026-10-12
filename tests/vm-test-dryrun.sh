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
