#!/usr/bin/env bash
# wrapper: bin/publish-sandbox --help -> bin/publish --sandbox --help
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/publish.sh" --sandbox "$@"
