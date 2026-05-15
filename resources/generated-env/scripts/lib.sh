#!/usr/bin/env bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

cd "$project_dir"

die() {
  echo "$*" >&2
  exit 1
}

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
wpmoo_env="${WPMOO_ENV:-dev}"
compose_file="compose/${wpmoo_env}.yaml"

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

if [[ ! "$wpmoo_env" =~ ^[A-Za-z0-9_.-]+$ || "$wpmoo_env" == -* || "$wpmoo_env" == *..* || "$wpmoo_env" == */* ]]; then
  die "Invalid WPMOO_ENV: $wpmoo_env"
fi

if [[ ! -f compose.yaml ]]; then
  die "Missing compose file: compose.yaml"
fi

if [[ ! -f "$compose_file" ]]; then
  die "Missing compose overlay: $compose_file"$'\n'"Set WPMOO_ENV to one of: dev, debug, test, stage, prod, proxy, tools"
fi

compose() {
  docker compose --project-directory "$project_dir" -f compose.yaml -f "$compose_file" "$@"
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
