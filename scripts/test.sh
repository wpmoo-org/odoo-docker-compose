#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$project_dir"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

module="${1:-${ODOO_TEST_MODULE:-}}"
if [[ -z "$module" ]]; then
  echo "Usage: $0 <module>" >&2
  echo "Or set ODOO_TEST_MODULE in .env." >&2
  exit 1
fi

db="${ODOO_TEST_DB:-${module}_test}"

"$script_dir/compose.sh" run --rm odoo odoo \
  -d "$db" \
  -i "$module" \
  --test-enable \
  --stop-after-init
