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
compose_file="docker-compose_${odoo_version}.yml"

if [[ ! -f "$compose_file" ]]; then
  echo "Missing compose file: $compose_file" >&2
  echo "Set ODOO_VERSION to one of: 17.0, 18.0, 19.0" >&2
  exit 1
fi

exec docker compose -f "$compose_file" "$@"
