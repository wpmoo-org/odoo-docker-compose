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

odoo_version="${ODOO_VERSION:-19.0}"
case "$odoo_version" in
  17.0) default_http_port=10017 ;;
  18.0) default_http_port=10018 ;;
  19.0) default_http_port=10019 ;;
  *) default_http_port=10019 ;;
esac

"$script_dir/compose.sh" up -d

echo "Odoo $odoo_version is starting on http://localhost:${HTTP_PORT:-$default_http_port}"
