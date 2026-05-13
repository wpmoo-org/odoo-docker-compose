#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

db="${1:-postgres}"
validate_db_name "$db"

compose exec db psql -U odoo -d "$db"
