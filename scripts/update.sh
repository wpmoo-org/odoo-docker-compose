#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modules="${1:-${ODOO_TEST_MODULE:-}}"
db="${2:-devel}"

[[ -n "$modules" ]] || die "Usage: $0 <module[,module]> [db]"
validate_module_list "$modules"
validate_db_name "$db"

compose run --rm odoo odoo -d "$db" -u "$modules" --stop-after-init
