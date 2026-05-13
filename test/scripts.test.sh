#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tests_run=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_log_contains() {
  local log_file="$1"
  local expected="$2"
  grep -F -- "$expected" "$log_file" >/dev/null ||
    fail "expected log to contain: $expected"$'\n'"actual log:"$'\n'"$(cat "$log_file")"
}

make_project() {
  local project
  project="$(mktemp -d)"
  mkdir -p "$project/bin" "$project/data/filestore/devel"
  cp -R "$repo_root/scripts" "$project/scripts"
  cp "$repo_root"/docker-compose_*.yml "$project/"
  cat >"$project/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s :: docker %s\n' "$PWD" "$*" >>"$DOCKER_STUB_LOG"

case " $* " in
  *" exec -T db pg_dump "*)
    printf 'stub dump for %s\n' "$*"
    ;;
  *" exec -T db psql "*)
    printf 'stub psql for %s\n' "$*"
    ;;
esac
STUB
  chmod +x "$project/bin/docker"
  printf '%s\n' "$project"
}

run_in_project() {
  local project="$1"
  shift
  (
    cd "$project"
    PATH="$project/bin:$PATH" DOCKER_STUB_LOG="$project/docker.log" "$@"
  )
}

test_compose_uses_env_version() {
  local project
  project="$(make_project)"
  echo "ODOO_VERSION=18.0" >"$project/.env"

  run_in_project "$project" ./scripts/compose.sh config

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_18.0.yml config"
}

test_resetdb_installs_requested_modules() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/resetdb.sh devel base,crm

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml stop odoo"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec -T db dropdb --if-exists -U odoo devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec -T db createdb -U odoo -O odoo devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm odoo odoo -d devel -i base,crm --stop-after-init"
}

test_module_lifecycle_scripts_use_stock_odoo_commands() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/install.sh sale devel
  run_in_project "$project" ./scripts/update.sh sale devel
  run_in_project "$project" ./scripts/uninstall.sh sale devel
  run_in_project "$project" ./scripts/test.sh sale --db devel --mode update --tags /sale

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm odoo odoo -d devel -i sale --stop-after-init"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm odoo odoo -d devel -u sale --stop-after-init"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm -T odoo odoo shell -d devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm odoo odoo -d devel -u sale --test-enable --stop-after-init --test-tags /sale"
}

test_test_script_positional_module_overrides_env_default() {
  local project
  project="$(make_project)"
  echo "ODOO_TEST_MODULE=env_module" >"$project/.env"

  run_in_project "$project" ./scripts/test.sh sale --db devel

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm odoo odoo -d devel -i sale --test-enable --stop-after-init --test-tags /sale"
}

test_snapshot_and_restore_include_database_and_filestore() {
  local project
  project="$(make_project)"
  echo "attachment" >"$project/data/filestore/devel/attachment.txt"

  run_in_project "$project" ./scripts/snapshot.sh devel snap1

  assert_file_exists "$project/backups/snapshots/snap1.dump"
  assert_file_exists "$project/backups/snapshots/snap1.filestore.tar.gz"
  assert_file_exists "$project/backups/snapshots/snap1.json"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec -T db pg_dump -U odoo -Fc devel"

  run_in_project "$project" ./scripts/restore-snapshot.sh snap1 devel

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml stop odoo"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec -T db dropdb --if-exists -U odoo devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec -T db createdb -U odoo -O odoo devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec -T db pg_restore -U odoo -d devel --clean --if-exists"
}

test_psql_and_restart_scripts_delegate_to_compose() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/psql.sh devel
  run_in_project "$project" ./scripts/restart.sh

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec db psql -U odoo -d devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml restart odoo"
}

for test_name in \
  test_compose_uses_env_version \
  test_resetdb_installs_requested_modules \
  test_module_lifecycle_scripts_use_stock_odoo_commands \
  test_test_script_positional_module_overrides_env_default \
  test_snapshot_and_restore_include_database_and_filestore \
  test_psql_and_restart_scripts_delegate_to_compose
do
  "$test_name"
  tests_run=$((tests_run + 1))
done

echo "scripts.test.sh: $tests_run tests passed"
