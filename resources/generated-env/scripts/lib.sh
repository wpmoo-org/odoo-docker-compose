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
postgres_version="${POSTGRES_VERSION:-18}"
wpmoo_env="${WPMOO_ENV:-dev}"
wpmoo_compose_overlays="${WPMOO_COMPOSE_OVERLAYS:-}"

default_http_port() {
  case "$odoo_version" in
    17.0) printf '10017' ;;
    18.0) printf '10018' ;;
    19.0) printf '10019' ;;
    *) printf '10019' ;;
  esac
}

default_gevent_port() {
  case "$odoo_version" in
    17.0) printf '20017' ;;
    18.0) printf '20018' ;;
    19.0) printf '20019' ;;
    *) printf '20019' ;;
  esac
}

export ODOO_IMAGE="${ODOO_IMAGE:-odoo:${odoo_version}}"
export POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:${postgres_version}}"
export HTTP_PORT="${HTTP_PORT:-$(default_http_port)}"
export GEVENT_PORT="${GEVENT_PORT:-$(default_gevent_port)}"

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

if [[ ! -f compose.yaml ]]; then
  die "Missing compose file: compose.yaml"
fi

case "$wpmoo_env" in
  dev | debug | test | stage | prod) ;;
  *)
    die "Invalid WPMOO_ENV: $wpmoo_env. Use one of: dev, debug, test, stage, prod."$'\n'"Use WPMOO_COMPOSE_OVERLAYS=proxy,tools for optional overlays."
    ;;
esac

compose_files=("compose/${wpmoo_env}.yaml")
compose_profiles=""

if [[ -n "$wpmoo_compose_overlays" ]]; then
  IFS=',' read -r -a overlay_array <<<"$wpmoo_compose_overlays"
  for overlay in "${overlay_array[@]}"; do
    overlay="$(trim_env_value "$overlay")"
    [[ -n "$overlay" ]] || continue
    case "$overlay" in
      proxy | tools) ;;
      *)
        die "Invalid WPMOO_COMPOSE_OVERLAYS entry: $overlay. Use comma-separated values from: proxy, tools."
        ;;
    esac
    compose_files+=("compose/${overlay}.yaml")
    compose_profiles="${compose_profiles}${compose_profiles:+ }${overlay}"
  done
fi

for compose_file in "${compose_files[@]}"; do
  [[ -f "$compose_file" ]] || die "Missing compose overlay: $compose_file"
done

compose() {
  local compose_args=()
  local compose_profile
  for compose_profile in $compose_profiles; do
    compose_args+=(--profile "$compose_profile")
  done
  compose_args+=(--project-directory "$project_dir" -f compose.yaml)
  local compose_file
  for compose_file in "${compose_files[@]}"; do
    compose_args+=(-f "$compose_file")
  done
  docker compose "${compose_args[@]}" "$@"
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
