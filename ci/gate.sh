#!/usr/bin/env bash
#
# The gate, as the cafaye CI runs it.
#
# kit is config-only: there is no runtime code and no library, so the gate is
# the suite that proves every artifact a service repository copies or calls
# actually parses. The suite is `tests/validate.sh`; this file is where the
# CI finds it.
set -euo pipefail
cd "$(dirname "$0")/.."

exec tests/validate.sh
