#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ -f .pre-commit-config.yaml ]]; then
  command -v pre-commit >/dev/null 2>&1 ||
    die "pre-commit is not installed. Install it or remove .pre-commit-config.yaml."
  pre-commit run -a
fi

"$script_dir/check-addons.sh"
