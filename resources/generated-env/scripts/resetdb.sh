#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

db="${1:-devel}"
modules="${2:-base}"

validate_db_name "$db"
validate_module_list "$modules"
require_destructive_allowed "resetdb"

compose stop odoo
compose exec -T db dropdb --if-exists -U odoo "$db"
compose exec -T db createdb -U odoo -O odoo "$db"
compose run --rm odoo odoo -d "$db" -i "$modules" --stop-after-init
