#!/usr/bin/env bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

cd "$project_dir"

trim_env_value() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

load_env_file() {
  local env_file="$1"
  local line key value

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="$(trim_env_value "$value")"
    printf -v "$key" '%s' "$value"
    export "$key"
  done <"$env_file"
}

load_env_file "$project_dir/.env"

odoo_version="${ODOO_VERSION:-19.0}"
compose_file="docker-compose_${odoo_version}.yml"
wpmoo_env="${WPMOO_ENV:-dev}"
wpmoo_allow_destructive="${WPMOO_ALLOW_DESTRUCTIVE:-}"
wpmoo_snapshot_retention_count="${WPMOO_SNAPSHOT_RETENTION_COUNT:-0}"

die() {
  echo "$*" >&2
  exit 1
}

script_usage_name() {
  local source
  for source in "${BASH_SOURCE[@]}"; do
    if [[ "$(basename "$source")" != "lib.sh" ]]; then
      printf './scripts/%s' "$(basename "$source")"
      return
    fi
  done
  printf './scripts/%s' "$(basename "$0")"
}

die_usage() {
  local usage_suffix="${1:-}"
  if [[ -n "$usage_suffix" ]]; then
    die "Usage: $(script_usage_name) $usage_suffix"
  fi
  die "Usage: $(script_usage_name)"
}

if [[ ! -f "$compose_file" ]]; then
  die "Missing compose file: $compose_file"$'\n'"Set ODOO_VERSION to one of: 17.0, 18.0, 19.0"
fi

require_non_default_secret() {
  local context="$1"
  local name="$2"
  local value="$3"
  local default_value="$4"

  if [[ -z "$value" || "$value" == "$default_value" || "$value" == replace-with-* || "$value" == change-me* ]]; then
    die "Refusing to run $context with default $name."$'\n'"Set $name to a non-default secret in .env before continuing."
  fi
}

require_safe_runtime_secrets() {
  case "$wpmoo_env" in
    stage | prod)
      require_non_default_secret "WPMOO_ENV=$wpmoo_env" "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD:-odoo}" "odoo"
      require_non_default_secret "WPMOO_ENV=$wpmoo_env" "ODOO_MASTER_PASSWORD" "${ODOO_MASTER_PASSWORD:-admin}" "admin"
      ;;
  esac
}

compose() {
  require_safe_runtime_secrets
  docker compose -f "$compose_file" "$@"
}

default_http_port() {
  case "$odoo_version" in
    17.0) printf '10017' ;;
    18.0) printf '10018' ;;
    19.0) printf '10019' ;;
    *) printf '10019' ;;
  esac
}

validate_db_name() {
  local db="$1"
  [[ "$db" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid database name: $db"
  [[ "$db" != -* ]] || die "Invalid database name: $db"
}

validate_snapshot_name() {
  local snapshot="$1"
  [[ "$snapshot" =~ ^[A-Za-z0-9_.-]+$ && "$snapshot" != -* ]] ||
    die "Invalid snapshot name: $snapshot. Use letters, numbers, dots, underscores, and dashes only; do not start with a dash."
}

is_truthy() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_destructive_allowed() {
  local action="$1"
  case "$wpmoo_env" in
    stage | prod)
      is_truthy "$wpmoo_allow_destructive" ||
        die "Refusing destructive database action '$action' in WPMOO_ENV=$wpmoo_env."$'\n'"Set WPMOO_ALLOW_DESTRUCTIVE=1 to continue."
      ;;
  esac
}

validate_snapshot_retention_count() {
  [[ "$wpmoo_snapshot_retention_count" =~ ^[0-9]+$ ]] ||
    die "Invalid WPMOO_SNAPSHOT_RETENTION_COUNT: $wpmoo_snapshot_retention_count. Use 0 or a positive integer."
}

prune_snapshots() {
  local snapshot_dir="$1"
  validate_snapshot_retention_count
  [[ "$wpmoo_snapshot_retention_count" -gt 0 ]] || return 0

  local manifests=()
  local manifest
  while IFS= read -r manifest; do
    manifests+=("$manifest")
  done < <(find "$snapshot_dir" -maxdepth 1 -type f -name '*.json' | sort)

  local excess=$((${#manifests[@]} - wpmoo_snapshot_retention_count))
  [[ "$excess" -gt 0 ]] || return 0

  local index stem
  for ((index = 0; index < excess; index += 1)); do
    stem="${manifests[$index]%.json}"
    rm -f "$stem.dump" "$stem.filestore.tar.gz" "$stem.json"
  done
}

validate_module_name() {
  local module="$1"
  [[ "$module" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid module name: $module"
}

validate_module_list() {
  local modules="$1"
  [[ -n "$modules" ]] || die "Module list is required."

  local module
  IFS=',' read -r -a module_array <<<"$modules"
  for module in "${module_array[@]}"; do
    validate_module_name "$module"
  done
}

first_module() {
  local modules="$1"
  printf '%s' "${modules%%,*}"
}

default_test_db() {
  local modules="$1"
  printf '%s' "${ODOO_TEST_DB:-$(first_module "$modules")_test}"
}

default_test_tags() {
  local modules="$1"
  printf '/%s' "${modules//,/,/}"
}
