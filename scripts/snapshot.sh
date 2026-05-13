#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

db="${1:-devel}"
snapshot="${2:-${db}-$(date +%Y_%m_%d-%H_%M)}"

validate_db_name "$db"
validate_snapshot_name "$snapshot"

snapshot_dir="$project_dir/backups/snapshots"
dump_path="$snapshot_dir/$snapshot.dump"
filestore_path="$snapshot_dir/$snapshot.filestore.tar.gz"
manifest_path="$snapshot_dir/$snapshot.json"

mkdir -p "$snapshot_dir"

compose exec -T db pg_dump -U odoo -Fc "$db" >"$dump_path"

if [[ -d "$project_dir/data/filestore/$db" ]]; then
  tar -czf "$filestore_path" -C "$project_dir/data/filestore" "$db"
else
  empty_dir="$(mktemp -d)"
  tar -czf "$filestore_path" -C "$empty_dir" .
  rmdir "$empty_dir"
fi

cat >"$manifest_path" <<EOF
{
  "name": "$snapshot",
  "database": "$db",
  "dump": "$(basename "$dump_path")",
  "filestore": "$(basename "$filestore_path")"
}
EOF

echo "Snapshot written to $snapshot_dir/$snapshot.*"
