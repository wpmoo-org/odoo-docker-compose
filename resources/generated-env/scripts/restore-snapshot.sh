#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ $# -le 2 ]] || die_usage "<snapshot-name> [db]"

snapshot="${1:-}"
db="${2:-devel}"

[[ -n "$snapshot" ]] || die_usage "<snapshot-name> [db]"
validate_snapshot_name "$snapshot"
validate_db_name "$db"

snapshot_dir="$project_dir/backups/snapshots"
dump_path="$snapshot_dir/$snapshot.dump"
filestore_path="$snapshot_dir/$snapshot.filestore.tar.gz"

[[ -f "$dump_path" ]] || die "Missing snapshot dump: $dump_path"
[[ -f "$filestore_path" ]] || die "Missing snapshot filestore: $filestore_path"

compose stop odoo
compose exec -T db dropdb --if-exists -U odoo "$db"
compose exec -T db createdb -U odoo -O odoo "$db"
compose exec -T db pg_restore -U odoo -d "$db" --clean --if-exists <"$dump_path"

rm -rf "$project_dir/data/filestore/$db"
mkdir -p "$project_dir/data/filestore"
tar -xzf "$filestore_path" -C "$project_dir/data/filestore"

echo "Snapshot $snapshot restored into database $db"
