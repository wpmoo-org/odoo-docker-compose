#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modules="${1:-${ODOO_TEST_MODULE:-}}"
db="${2:-devel}"
output="${3:-i18n/$(first_module "${modules:-module}").pot}"

[[ -n "$modules" ]] || die "Usage: $0 <module[,module]> [db] [output]"
validate_module_list "$modules"
validate_db_name "$db"

mkdir -p "$(dirname "$project_dir/$output")"

IFS=',' read -r -a module_array <<<"$modules"

compose run --rm -v "$project_dir:/mnt/project" odoo bash -lc '
set -euo pipefail
db="$1"
output="$2"
shift 2
config="$(mktemp)"
trap '\''rm -f "$config"'\'' EXIT
cp /etc/odoo/odoo.conf "$config"
printf "\ndb_password = %s\n" "${PASSWORD:-odoo}" >>"$config"
wait-for-psql.py \
  --db_host "${HOST:-db}" \
  --db_port "${PORT:-5432}" \
  --db_user "${USER:-odoo}" \
  --db_password "${PASSWORD:-odoo}" \
  --timeout=30
odoo i18n export -c "$config" -d "$db" -o "$output" "$@"
' bash "$db" "/mnt/project/$output" "${module_array[@]}"

if [[ -f "$project_dir/$output" ]]; then
  cat "$project_dir/$output"
else
  echo "POT export requested at $output"
fi
