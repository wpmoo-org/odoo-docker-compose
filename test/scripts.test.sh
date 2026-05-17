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

assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    fail "expected file not to contain: $unexpected"$'\n'"actual file:"$'\n'"$(cat "$file")"
  fi
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
  cp -R "$repo_root/resources/generated-env/." "$project/"
  cat >"$project/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s :: HTTP_PORT=%s GEVENT_PORT=%s :: docker %s\n' "$PWD" "${HTTP_PORT:-}" "${GEVENT_PORT:-}" "$*" >>"$DOCKER_STUB_LOG"

case " $* " in
  *" exec -T db pg_dump "*)
    printf 'stub dump for %s\n' "$*"
    ;;
  *" exec -T db psql "*)
    if [[ "$*" == *"pg_database"* ]]; then
      printf '%s\n' "${DOCKER_STUB_DATABASE_EXISTS:-}"
    elif [[ "$*" == *"ir_module_module"* ]]; then
      printf '%s\n' "${DOCKER_STUB_INSTALLED_MODULE_COUNT:-0}"
    else
      printf 'stub psql for %s\n' "$*"
    fi
    ;;
esac
STUB
  chmod +x "$project/bin/docker"
  printf '%s\n' "$project"
}

compose_expectation() {
  local project="$1"
  local env_name="$2"
  local command_suffix="$3"
  shift 3

  local args
  args="docker compose"
  local overlay
  for overlay in "$@"; do
    case "$overlay" in
      proxy | tools)
        args+=" --profile $overlay"
        ;;
    esac
  done
  args+=" --project-directory $project -f compose.yaml -f compose/$env_name.yaml"
  for overlay in "$@"; do
    args+=" -f compose/$overlay.yaml"
  done
  printf '%s %s' "$args" "$command_suffix"
}

assert_compose_log_contains() {
  local project="$1"
  local env_name="$2"
  local command_suffix="$3"
  shift 3
  assert_log_contains "$project/docker.log" "$(compose_expectation "$project" "$env_name" "$command_suffix" "$@")"
}

run_in_project() {
  local project="$1"
  shift
  (
    cd "$project"
    PATH="$project/bin:$PATH" DOCKER_STUB_LOG="$project/docker.log" "$@"
  )
}

test_compose_uses_default_dev_overlay() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/compose.sh config

  assert_compose_log_contains "$project" dev "config"
}

test_legacy_compose_files_are_compatible() {
  assert_file_contains "$repo_root/docker-compose_19.0.yml" "/var/lib/postgresql"
  assert_file_not_contains "$repo_root/docker-compose_19.0.yml" "/var/lib/postgresql/18/docker"

  assert_file_contains "$repo_root/docker-compose_18.0.yml" "/var/lib/postgresql/data"
  assert_file_contains "$repo_root/docker-compose_17.0.yml" "/var/lib/postgresql/data"
}

test_generated_env_mounts_postgres_parent_directory() {
  local overlay

  for overlay in dev debug stage prod; do
    assert_file_contains "$repo_root/resources/generated-env/compose/$overlay.yaml" "/var/lib/postgresql"
    assert_file_not_contains "$repo_root/resources/generated-env/compose/$overlay.yaml" "/var/lib/postgresql/data"
  done

  assert_file_contains "$repo_root/resources/generated-env/compose/test.yaml" "/var/lib/postgresql"
  assert_file_not_contains "$repo_root/resources/generated-env/compose/test.yaml" "/var/lib/postgresql/data"
}

test_compose_uses_stage_overlay_from_env() {
  local project
  project="$(make_project)"
  cat >"$project/.env" <<'ENV'
WPMOO_ENV=stage
POSTGRES_PASSWORD=stage-db-secret
ODOO_MASTER_PASSWORD=stage-master-secret
ENV

  run_in_project "$project" ./scripts/compose.sh config

  assert_compose_log_contains "$project" stage "config"
}

test_compose_uses_optional_overlays_from_env() {
  local project
  project="$(make_project)"
  cat >"$project/.env" <<'ENV'
WPMOO_ENV=stage
POSTGRES_PASSWORD=stage-db-secret
ODOO_MASTER_PASSWORD=stage-master-secret
WPMOO_COMPOSE_OVERLAYS=proxy,tools
ENV

  run_in_project "$project" ./scripts/compose.sh config

  assert_compose_log_contains "$project" stage "config" proxy tools
}

test_compose_blocks_exposed_env_with_default_secrets() {
  local project
  project="$(make_project)"
  echo "WPMOO_ENV=prod" >"$project/.env"

  if run_in_project "$project" ./scripts/compose.sh config >"$project/prod-default.out" 2>"$project/prod-default.err"; then
    fail "expected prod compose to fail with default secrets"
  fi

  assert_file_contains "$project/prod-default.err" "Refusing to run WPMOO_ENV=prod with default POSTGRES_PASSWORD."
  [[ ! -f "$project/docker.log" ]] || fail "default-secret guard must run before docker compose"
}

test_compose_blocks_proxy_overlay_with_default_secrets() {
  local project
  project="$(make_project)"
  echo "WPMOO_COMPOSE_OVERLAYS=proxy" >"$project/.env"

  if run_in_project "$project" ./scripts/compose.sh config >"$project/proxy-default.out" 2>"$project/proxy-default.err"; then
    fail "expected proxy compose to fail with default secrets"
  fi

  assert_file_contains "$project/proxy-default.err" "Refusing to run proxy overlay with default POSTGRES_PASSWORD."
  [[ ! -f "$project/docker.log" ]] || fail "default-secret guard must run before docker compose"
}

test_dev_ports_bind_to_localhost_by_default() {
  assert_file_contains "$repo_root/resources/generated-env/compose/dev.yaml" '"${POSTGRES_HOST:-127.0.0.1}:${POSTGRES_PORT:-5432}:5432"'
  assert_file_contains "$repo_root/resources/generated-env/compose/dev.yaml" '"${ODOO_HTTP_HOST:-127.0.0.1}:${HTTP_PORT:-10019}:8069"'
  assert_file_contains "$repo_root/resources/generated-env/compose/debug.yaml" '"${ODOO_HTTP_HOST:-127.0.0.1}:${HTTP_PORT:-10019}:8069"'
}

test_legacy_env_file_does_not_execute_shell() {
  local project
  project="$(mktemp -d)"
  mkdir -p "$project/bin" "$project/scripts"
  cp "$repo_root/docker-compose_19.0.yml" "$project/docker-compose_19.0.yml"
  cp "$repo_root/scripts/lib.sh" "$repo_root/scripts/compose.sh" "$project/scripts/"
  cat >"$project/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$DOCKER_STUB_LOG"
STUB
  chmod +x "$project/bin/docker"
  cat >"$project/.env" <<ENV
HTTP_PORT=\$(touch "$project/env-executed")
GEVENT_PORT=20019
ENV

  (
    cd "$project"
    PATH="$project/bin:$PATH" DOCKER_STUB_LOG="$project/docker.log" ./scripts/compose.sh config
  )

  [[ ! -e "$project/env-executed" ]] || fail "legacy .env parser executed shell command substitution"
  assert_file_contains "$project/docker.log" "docker compose -f docker-compose_19.0.yml config"
}

test_compose_derives_ports_from_odoo_version() {
  local project
  project="$(make_project)"
  echo "ODOO_VERSION=18.0" >"$project/.env"

  run_in_project "$project" ./scripts/compose.sh config

  assert_file_contains "$project/docker.log" "HTTP_PORT=10018 GEVENT_PORT=20018"
  assert_compose_log_contains "$project" dev "config"
}

test_compose_rejects_optional_overlay_as_primary_env() {
  local env_name project
  for env_name in proxy tools; do
    project="$(make_project)"
    echo "WPMOO_ENV=$env_name" >"$project/.env"

    if run_in_project "$project" ./scripts/compose.sh config >"$project/$env_name-env.out" 2>"$project/$env_name-env.err"; then
      fail "expected WPMOO_ENV=$env_name to fail"
    fi

    assert_file_contains "$project/$env_name-env.err" "Invalid WPMOO_ENV: $env_name. Use one of: dev, debug, test, stage, prod."
    assert_file_contains "$project/$env_name-env.err" "Use WPMOO_COMPOSE_OVERLAYS=proxy,tools for optional overlays."
  done
}

test_entrypoint_enables_proxy_mode_from_environment() {
  local project
  project="$(make_project)"
  cp "$project/config/odoo/odoo.conf" "$project/readonly-odoo.conf"
  chmod a-w "$project/readonly-odoo.conf"
  cat >"$project/bin/wait-for-psql.py" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'wait-for-psql.py %s\n' "$*" >>"$ENTRYPOINT_STUB_LOG"
STUB
  cat >"$project/bin/odoo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'odoo %s\n' "$*" >>"$ENTRYPOINT_STUB_LOG"
grep -E '^[[:space:]]*proxy_mode[[:space:]]*=' "$ODOO_RC" >"$ENTRYPOINT_PROXY_MODE_OUT"
STUB
  chmod +x "$project/bin/wait-for-psql.py" "$project/bin/odoo"

  (
    cd "$project"
    PATH="$project/bin:$PATH" \
      ODOO_RC="$project/readonly-odoo.conf" \
      ODOO_MASTER_PASSWORD="" \
      PROXY_MODE=1 \
      WPMOO_ADDONS_DIR="$project/wpmoo-addons" \
      WPMOO_SRC_DIR="$project/odoo/custom/src/private" \
      ENTRYPOINT_STUB_LOG="$project/entrypoint.log" \
      ENTRYPOINT_PROXY_MODE_OUT="$project/proxy-mode.out" \
      ./resources/odoo/entrypoint.sh --
  )

  assert_file_contains "$project/proxy-mode.out" "proxy_mode = True"
}

test_resetdb_installs_requested_modules() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/resetdb.sh devel base,crm

  assert_compose_log_contains "$project" dev "stop odoo"
  assert_compose_log_contains "$project" dev "exec -T db dropdb --if-exists -U odoo devel"
  assert_compose_log_contains "$project" dev "exec -T db createdb -U odoo -O odoo devel"
  assert_compose_log_contains "$project" dev "run --rm odoo odoo -d devel -i base,crm --stop-after-init"
}

test_module_lifecycle_scripts_use_stock_odoo_commands() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/install.sh sale devel
  run_in_project "$project" ./scripts/update.sh sale devel
  run_in_project "$project" ./scripts/uninstall.sh sale devel
  run_in_project "$project" ./scripts/test.sh sale --db devel --mode update --tags /sale

  assert_compose_log_contains "$project" dev "run --rm odoo odoo -d devel -i sale --stop-after-init"
  assert_compose_log_contains "$project" dev "run --rm odoo odoo -d devel -u sale --stop-after-init"
  assert_compose_log_contains "$project" dev "run --rm -T odoo odoo shell -d devel"
  assert_compose_log_contains "$project" dev "run --rm odoo odoo -d devel -u sale --test-enable --stop-after-init --test-tags /sale"
}

test_test_script_positional_module_overrides_env_default() {
  local project
  project="$(make_project)"
  echo "ODOO_TEST_MODULE=env_module" >"$project/.env"

  run_in_project "$project" ./scripts/test.sh sale --db devel

  assert_compose_log_contains "$project" dev "run --rm odoo odoo -d devel -i sale --test-enable --stop-after-init --test-tags /sale"
}

test_test_script_auto_mode_updates_installed_modules() {
  local project
  project="$(make_project)"

  DOCKER_STUB_DATABASE_EXISTS=1 DOCKER_STUB_INSTALLED_MODULE_COUNT=1 run_in_project "$project" ./scripts/test.sh sale --db devel

  assert_compose_log_contains "$project" dev "run --rm odoo odoo -d devel -u sale --test-enable --stop-after-init --test-tags /sale"
}

test_snapshot_and_restore_include_database_and_filestore() {
  local project
  project="$(make_project)"
  echo "attachment" >"$project/data/filestore/devel/attachment.txt"

  run_in_project "$project" ./scripts/snapshot.sh devel snap1

  assert_file_exists "$project/backups/snapshots/snap1.dump"
  assert_file_exists "$project/backups/snapshots/snap1.filestore.tar.gz"
  assert_file_exists "$project/backups/snapshots/snap1.json"
  assert_compose_log_contains "$project" dev "exec -T db pg_dump -U odoo -Fc devel"

  run_in_project "$project" ./scripts/restore-snapshot.sh snap1 devel

  assert_compose_log_contains "$project" dev "stop odoo"
  assert_compose_log_contains "$project" dev "exec -T db dropdb --if-exists -U odoo devel"
  assert_compose_log_contains "$project" dev "exec -T db createdb -U odoo -O odoo devel"
  assert_compose_log_contains "$project" dev "exec -T db pg_restore -U odoo -d devel --clean --if-exists"
}

test_restore_snapshot_dry_run_reports_plan_without_compose() {
  local project
  project="$(make_project)"
  mkdir -p "$project/backups/snapshots"
  printf 'dump\n' >"$project/backups/snapshots/snap1.dump"
  tar -czf "$project/backups/snapshots/snap1.filestore.tar.gz" -C "$project/data/filestore" devel

  run_in_project "$project" ./scripts/restore-snapshot.sh --dry-run snap1 devel >"$project/restore-preview.out"

  assert_file_contains "$project/restore-preview.out" "Restore snapshot preview"
  assert_file_contains "$project/restore-preview.out" "Snapshot: snap1"
  assert_file_contains "$project/restore-preview.out" "Database: devel"
  assert_file_contains "$project/restore-preview.out" "No changes were made."
  [[ ! -f "$project/docker.log" ]] || fail "restore dry-run must not call docker compose"
}

test_destructive_database_actions_require_stage_prod_confirmation() {
  local project
  project="$(make_project)"
  cat >"$project/.env" <<'ENV'
WPMOO_ENV=stage
POSTGRES_PASSWORD=stage-db-secret
ODOO_MASTER_PASSWORD=stage-master-secret
ENV

  if run_in_project "$project" ./scripts/resetdb.sh devel base >"$project/resetdb-stage.out" 2>"$project/resetdb-stage.err"; then
    fail "expected resetdb to fail in stage without explicit destructive allow"
  fi
  assert_file_contains "$project/resetdb-stage.err" "Refusing destructive database action 'resetdb' in WPMOO_ENV=stage."
  assert_file_contains "$project/resetdb-stage.err" "Set WPMOO_ALLOW_DESTRUCTIVE=1 to continue."

  if run_in_project "$project" ./scripts/restore-snapshot.sh snap1 devel >"$project/restore-stage.out" 2>"$project/restore-stage.err"; then
    fail "expected restore-snapshot to fail in stage without explicit destructive allow"
  fi
  assert_file_contains "$project/restore-stage.err" "Refusing destructive database action 'restore-snapshot' in WPMOO_ENV=stage."
}

test_destructive_database_actions_allow_explicit_stage_confirmation() {
  local project
  project="$(make_project)"
  cat >"$project/.env" <<'ENV'
WPMOO_ENV=stage
WPMOO_ALLOW_DESTRUCTIVE=1
POSTGRES_PASSWORD=stage-db-secret
ODOO_MASTER_PASSWORD=stage-master-secret
ENV

  run_in_project "$project" ./scripts/resetdb.sh devel base

  assert_compose_log_contains "$project" stage "exec -T db dropdb --if-exists -U odoo devel"
}

test_snapshot_retention_prunes_old_snapshot_files() {
  local project snapshot_dir
  project="$(make_project)"
  snapshot_dir="$project/backups/snapshots"
  mkdir -p "$snapshot_dir"
  for snapshot in snap-a snap-b; do
    printf 'dump\n' >"$snapshot_dir/$snapshot.dump"
    printf '{}\n' >"$snapshot_dir/$snapshot.json"
    tar -czf "$snapshot_dir/$snapshot.filestore.tar.gz" -C "$project/data/filestore" devel
  done
  echo "WPMOO_SNAPSHOT_RETENTION_COUNT=2" >"$project/.env"

  run_in_project "$project" ./scripts/snapshot.sh devel snap-c

  [[ ! -e "$snapshot_dir/snap-a.dump" ]] || fail "expected oldest snapshot dump to be pruned"
  [[ ! -e "$snapshot_dir/snap-a.filestore.tar.gz" ]] || fail "expected oldest snapshot filestore to be pruned"
  [[ ! -e "$snapshot_dir/snap-a.json" ]] || fail "expected oldest snapshot manifest to be pruned"
  assert_file_exists "$snapshot_dir/snap-b.dump"
  assert_file_exists "$snapshot_dir/snap-c.dump"
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
  assert_file_contains "$project/restore-usage.err" "Usage: ./scripts/restore-snapshot.sh [--dry-run] <snapshot-name> [db]"
}

test_psql_and_restart_scripts_delegate_to_compose() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/psql.sh devel
  run_in_project "$project" ./scripts/restart.sh

  assert_compose_log_contains "$project" dev "exec db psql -U odoo -d devel"
  assert_compose_log_contains "$project" dev "restart odoo"
}

test_pot_exports_with_odoo_i18n_command() {
  local project
  project="$(make_project)"

  run_in_project "$project" ./scripts/pot.sh sale devel i18n/sale.pot

  assert_compose_log_contains "$project" dev "run --rm -v $project:/mnt/project odoo bash -lc"
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
  assert_file_contains "$project/check-invalid.err" "addons/bad_module/__manifest__.py: addon 'bad_module' field 'version': must start with 19.0."
}

test_check_addons_blocks_public_dependencies_on_private_addons() {
  local project
  project="$(make_project)"
  mkdir -p "$project/addons/community_module" "$project/odoo/custom/src/private/private_paid"
  cat >"$project/addons/community_module/__manifest__.py" <<'MANIFEST'
{
    "name": "Community Module",
    "version": "19.0.1.0.0",
    "depends": ["base", "private_paid"],
    "license": "LGPL-3",
}
MANIFEST
  cat >"$project/odoo/custom/src/private/private_paid/__manifest__.py" <<'MANIFEST'
{
    "name": "Private Paid",
    "version": "19.0.1.0.0",
    "depends": ["base"],
    "license": "OPL-1",
}
MANIFEST

  if run_in_project "$project" ./scripts/check-addons.sh >"$project/check-private-dep.out" 2>"$project/check-private-dep.err"; then
    fail "expected check-addons to fail when a public addon depends on a private addon"
  fi
  assert_file_contains "$project/check-private-dep.err" "addons/community_module/__manifest__.py: addon 'community_module' field 'depends': public addon must not depend on private addon 'private_paid'"
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
  test_compose_uses_default_dev_overlay \
  test_generated_env_mounts_postgres_parent_directory \
  test_compose_uses_stage_overlay_from_env \
  test_legacy_compose_files_are_compatible \
  test_compose_uses_optional_overlays_from_env \
  test_compose_derives_ports_from_odoo_version \
  test_compose_rejects_optional_overlay_as_primary_env \
  test_compose_blocks_exposed_env_with_default_secrets \
  test_compose_blocks_proxy_overlay_with_default_secrets \
  test_dev_ports_bind_to_localhost_by_default \
  test_legacy_env_file_does_not_execute_shell \
  test_entrypoint_enables_proxy_mode_from_environment \
  test_resetdb_installs_requested_modules \
  test_module_lifecycle_scripts_use_stock_odoo_commands \
  test_test_script_positional_module_overrides_env_default \
  test_test_script_auto_mode_updates_installed_modules \
  test_snapshot_and_restore_include_database_and_filestore \
  test_restore_snapshot_dry_run_reports_plan_without_compose \
  test_destructive_database_actions_require_stage_prod_confirmation \
  test_destructive_database_actions_allow_explicit_stage_confirmation \
  test_snapshot_retention_prunes_old_snapshot_files \
  test_snapshot_and_restore_usage_errors_are_clear \
  test_psql_and_restart_scripts_delegate_to_compose \
  test_pot_exports_with_odoo_i18n_command \
  test_pot_usage_errors_are_clear \
  test_check_addons_validates_manifest_metadata \
  test_check_addons_blocks_public_dependencies_on_private_addons \
  test_lint_runs_pre_commit_when_configured_and_addon_check \
  test_lint_usage_errors_are_clear
do
  "$test_name"
  tests_run=$((tests_run + 1))
done

echo "scripts.test.sh: $tests_run tests passed"
