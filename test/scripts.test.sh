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

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" >/dev/null ||
    fail "expected file to contain: $expected"$'\n'"actual file:"$'\n'"$(cat "$file")"
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

test_snapshot_and_restore_usage_errors_are_clear() {
  local project
  project="$(make_project)"

  if run_in_project "$project" ./scripts/snapshot.sh devel bad/snap >"$project/snapshot-invalid.out" 2>"$project/snapshot-invalid.err"; then
    fail "expected snapshot to fail for invalid snapshot name"
  fi
  assert_file_contains "$project/snapshot-invalid.err" "Invalid snapshot name: bad/snap. Use letters, numbers, dots, underscores, and dashes only; do not start with a dash."

  if run_in_project "$project" ./scripts/snapshot.sh devel snap1 extra >"$project/snapshot-usage.out" 2>"$project/snapshot-usage.err"; then
    fail "expected snapshot to fail for too many arguments"
  fi
  assert_file_contains "$project/snapshot-usage.err" "Usage: ./scripts/snapshot.sh [db] [snapshot-name]"

  if run_in_project "$project" ./scripts/restore-snapshot.sh bad/snap >"$project/restore-invalid.out" 2>"$project/restore-invalid.err"; then
    fail "expected restore to fail for invalid snapshot name"
  fi
  assert_file_contains "$project/restore-invalid.err" "Invalid snapshot name: bad/snap. Use letters, numbers, dots, underscores, and dashes only; do not start with a dash."

  if run_in_project "$project" ./scripts/restore-snapshot.sh >"$project/restore-usage.out" 2>"$project/restore-usage.err"; then
    fail "expected restore to fail without snapshot name"
  fi
  assert_file_contains "$project/restore-usage.err" "Usage: ./scripts/restore-snapshot.sh <snapshot-name> [db]"
}

test_psql_and_restart_scripts_delegate_to_compose() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/psql.sh devel
  run_in_project "$project" ./scripts/restart.sh

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml exec db psql -U odoo -d devel"
  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml restart odoo"
}

test_pot_exports_with_odoo_i18n_command() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/pot.sh sale devel i18n/sale.pot

  assert_log_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml run --rm -v $project:/mnt/project odoo bash -lc"
  assert_log_contains "$project/docker.log" "bash devel /mnt/project/i18n/sale.pot sale"
}

test_pot_usage_errors_are_clear() {
  local project
  project="$(make_project)"

  if run_in_project "$project" ./scripts/pot.sh >"$project/pot-usage.out" 2>"$project/pot-usage.err"; then
    fail "expected pot to fail without a module list"
  fi
  assert_file_contains "$project/pot-usage.err" "Usage: ./scripts/pot.sh <module[,module]> [db] [output]"
  assert_file_contains "$project/pot-usage.err" "Or set ODOO_TEST_MODULE in .env."

  if run_in_project "$project" ./scripts/pot.sh sale devel i18n/sale.pot extra >"$project/pot-extra.out" 2>"$project/pot-extra.err"; then
    fail "expected pot to fail for too many arguments"
  fi
  assert_file_contains "$project/pot-extra.err" "Usage: ./scripts/pot.sh <module[,module]> [db] [output]"
}

test_check_addons_validates_manifest_metadata() {
  local project
  project="$(make_project)"
  mkdir -p "$project/addons/valid_module" "$project/addons/bad_module"
  cat >"$project/addons/valid_module/__manifest__.py" <<'MANIFEST'
{
    "name": "Valid Module",
    "version": "19.0.1.0.0",
    "depends": ["base"],
    "license": "LGPL-3",
    "installable": True,
}
MANIFEST

  run_in_project "$project" ./scripts/check-addons.sh >"$project/check-valid.out"
  assert_file_contains "$project/check-valid.out" "Checked 1 addon manifest"

  cat >"$project/addons/bad_module/__manifest__.py" <<'MANIFEST'
{
    "name": "Bad Module",
    "version": "18.0.1.0.0",
    "depends": ["base"],
    "license": "LGPL-3",
}
MANIFEST

  if run_in_project "$project" ./scripts/check-addons.sh >"$project/check-invalid.out" 2>"$project/check-invalid.err"; then
    fail "expected check-addons to fail for mismatched manifest version"
  fi
  assert_file_contains "$project/check-invalid.err" "version must start with 19.0."
}

test_lint_runs_pre_commit_when_configured_and_addon_check() {
  local project
  project="$(make_project)"
  mkdir -p "$project/addons/valid_module"
  touch "$project/.pre-commit-config.yaml"
  cat >"$project/addons/valid_module/__manifest__.py" <<'MANIFEST'
{
    "name": "Valid Module",
    "version": "19.0.1.0.0",
    "depends": ["base"],
    "license": "LGPL-3",
}
MANIFEST
  cat >"$project/bin/pre-commit" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'pre-commit %s\n' "$*" >>"$PRECOMMIT_STUB_LOG"
STUB
  chmod +x "$project/bin/pre-commit"

  (
    cd "$project"
    PATH="$project/bin:$PATH" \
      DOCKER_STUB_LOG="$project/docker.log" \
      PRECOMMIT_STUB_LOG="$project/pre-commit.log" \
      ./scripts/lint.sh >"$project/lint.out"
  )

  assert_file_contains "$project/pre-commit.log" "pre-commit run -a"
  assert_file_contains "$project/lint.out" "Checked 1 addon manifest"
}

test_lint_usage_errors_are_clear() {
  local project
  project="$(make_project)"

  if run_in_project "$project" ./scripts/lint.sh unexpected >"$project/lint-usage.out" 2>"$project/lint-usage.err"; then
    fail "expected lint to fail for unexpected arguments"
  fi
  assert_file_contains "$project/lint-usage.err" "Usage: ./scripts/lint.sh"
}

for test_name in \
  test_compose_uses_env_version \
  test_resetdb_installs_requested_modules \
  test_module_lifecycle_scripts_use_stock_odoo_commands \
  test_test_script_positional_module_overrides_env_default \
  test_snapshot_and_restore_include_database_and_filestore \
  test_snapshot_and_restore_usage_errors_are_clear \
  test_psql_and_restart_scripts_delegate_to_compose \
  test_pot_exports_with_odoo_i18n_command \
  test_pot_usage_errors_are_clear \
  test_check_addons_validates_manifest_metadata \
  test_lint_runs_pre_commit_when_configured_and_addon_check \
  test_lint_usage_errors_are_clear
do
  "$test_name"
  tests_run=$((tests_run + 1))
done

echo "scripts.test.sh: $tests_run tests passed"
