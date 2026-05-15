#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

python3 "$script_dir/check-addons.py" --odoo-version "$odoo_version" "$@"
