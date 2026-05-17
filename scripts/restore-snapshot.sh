#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi

[[ $# -le 2 ]] || die_usage "[--dry-run] <snapshot-name> [db]"

snapshot="${1:-}"
db="${2:-devel}"

[[ -n "$snapshot" ]] || die_usage "[--dry-run] <snapshot-name> [db]"
validate_snapshot_name "$snapshot"
validate_db_name "$db"

snapshot_dir="$project_dir/backups/snapshots"
dump_path="$snapshot_dir/$snapshot.dump"
filestore_path="$snapshot_dir/$snapshot.filestore.tar.gz"

if [[ "$dry_run" -eq 0 ]]; then
  require_destructive_allowed "restore-snapshot" "$db"
fi

[[ -f "$dump_path" ]] || die "Missing snapshot dump: $dump_path"
[[ -f "$filestore_path" ]] || die "Missing snapshot filestore: $filestore_path"

if [[ "$dry_run" -eq 1 ]]; then
  cat <<EOF
Restore snapshot preview
Snapshot: $snapshot
Database: $db
Dump: $dump_path
Filestore: $filestore_path
No changes were made.
EOF
  exit 0
fi

compose stop odoo
compose exec -T db dropdb --if-exists -U odoo "$db"
compose exec -T db createdb -U odoo -O odoo "$db"
compose exec -T db pg_restore -U odoo -d "$db" --clean --if-exists <"$dump_path"

rm -rf "$project_dir/data/filestore/$db"
mkdir -p "$project_dir/data/filestore"
tar -xzf "$filestore_path" -C "$project_dir/data/filestore"

echo "Snapshot $snapshot restored into database $db"
