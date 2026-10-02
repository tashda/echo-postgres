#!/bin/bash
# The checks CI's unit job runs, on this machine: build with tests, then the unit tests.
#
#   .github/scripts/ci-local.sh            run the checks
#   .github/scripts/ci-local.sh --install  run them automatically before every `git push`
#
# Server tests skip without POSTGRES_TEST_URL; start a server with the lab (see echo-server-lab) to run them.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "${1:-}" = "--install" ]; then
  hook="$(git rev-parse --git-path hooks/pre-push)"
  printf '#!/bin/bash\nexec "$(git rev-parse --show-toplevel)/.github/scripts/ci-local.sh"\n' > "$hook"
  chmod +x "$hook"
  echo "Installed $hook"
  exit 0
fi

swift build --build-tests
swift test
