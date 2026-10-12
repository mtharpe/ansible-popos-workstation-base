#!/usr/bin/env bash
# run.sh must give up after a bounded number of failed playbook runs and
# always remove the passwordless-sudo drop-in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
calls="${tmp}/calls"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"${tmp}/bin/$1"; chmod +x "${tmp}/bin/$1"; }
stub pipx 'exit 0'
stub ansible 'exit 0'
stub ansible-galaxy 'exit 0'
stub ansible-playbook "echo playbook >>'${calls}'; exit 2"
stub sudo "echo \"sudo \$*\" >>'${calls}'; cat >/dev/null 2>&1 || true"

set +e
# run.sh prepends ~/.local/bin; point HOME at the sandbox so stubs win.
HOME="${tmp}" PATH="${tmp}/bin:${PATH}" RUN_RETRY_DELAY=0 timeout 20 ./run.sh >/dev/null 2>&1
rc=$?
set -e

[ "${rc}" -ne 124 ] || { echo "run.sh retried until timeout"; exit 1; }
[ "${rc}" -ne 0 ] || { echo "run.sh reported success after failed runs"; exit 1; }
n="$(grep -c '^playbook' "${calls}")"
[ "${n}" -eq 3 ] || { echo "expected 3 playbook attempts, got ${n}"; exit 1; }
grep -q '^sudo rm -f /etc/sudoers.d/' "${calls}" || { echo "sudoers drop-in not removed"; exit 1; }
echo ok
