#!/usr/bin/env python3
import argparse
import ast
from pathlib import Path
import sys
from typing import Optional


SKIP_DIRS = {'.git', '.mypy_cache', '.pytest_cache', '.ruff_cache', '__pycache__', 'node_modules'}
PUBLIC_ADDONS_ROOT = Path('addons')
PRIVATE_ADDONS_ROOT = Path('odoo/custom/src/private')


class ManifestError(ValueError):
    def __init__(self, field: Optional[str], message: str) -> None:
        super().__init__(message)
        self.field = field
        self.message = message


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Validate local Odoo addon manifests.')
    parser.add_argument(
        '--odoo-version',
        default='19.0',
        help='Expected Odoo version prefix, for example 19.0.',
    )
    parser.add_argument(
        'paths',
        nargs='*',
        default=['addons', 'odoo/custom/src/private'],
        help='Directories to scan for __manifest__.py files.',
    )
    return parser.parse_args()


def iter_manifests(paths: list[str]) -> list[Path]:
    manifests: list[Path] = []
    for raw_path in paths:
        root = Path(raw_path)
        if not root.exists():
            continue
        if root.is_file() and root.name == '__manifest__.py':
            manifests.append(root)
            continue
        for manifest in root.rglob('__manifest__.py'):
            if SKIP_DIRS.intersection(manifest.parts):
                continue
            manifests.append(manifest)
    return sorted(set(manifests))


def read_manifest(path: Path) -> dict:
    try:
        parsed = ast.literal_eval(path.read_text(encoding='utf-8'))
    except (SyntaxError, ValueError) as error:
        raise ManifestError(None, f'must be a Python literal dict: {error}') from error

    if not isinstance(parsed, dict):
        raise ManifestError(None, 'must be a Python literal dict')
    return parsed


def require_string(manifest: dict, key: str) -> str:
    value = manifest.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ManifestError(key, 'must be a non-empty string')
    return value


def require_string_list(manifest: dict, key: str, required: bool = False) -> list[str]:
    value = manifest.get(key)
    if value is None:
        if required:
            raise ManifestError(key, 'must be a list of non-empty strings')
        return []
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ManifestError(key, 'must be a list of non-empty strings')
    return value


def is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def addon_name(path: Path) -> str:
    return path.parent.name


def format_manifest_error(path: Path, error: ManifestError) -> str:
    prefix = f"addon '{addon_name(path)}'"
    if error.field is not None:
        return f"{prefix} field '{error.field}': {error.message}"
    return f'{prefix} manifest: {error.message}'


def private_addon_names(manifests: list[Path]) -> set[str]:
    return {addon_name(manifest) for manifest in manifests if is_under(manifest, PRIVATE_ADDONS_ROOT)}


def validate_manifest(path: Path, odoo_version: str, private_addons: set[str]) -> list[str]:
    errors: list[str] = []
    try:
        manifest = read_manifest(path)
        version = require_string(manifest, 'version')
        require_string(manifest, 'license')
        depends = require_string_list(manifest, 'depends', required=True)
        require_string_list(manifest, 'data')
        require_string_list(manifest, 'demo')

        if not version.startswith(f'{odoo_version}.'):
            errors.append(format_manifest_error(path, ManifestError('version', f'must start with {odoo_version}.')))
        for key in ('installable', 'application'):
            if key in manifest and not isinstance(manifest[key], bool):
                errors.append(format_manifest_error(path, ManifestError(key, 'must be a boolean when present')))
        if is_under(path, PUBLIC_ADDONS_ROOT):
            for dependency in sorted(set(depends).intersection(private_addons)):
                errors.append(
                    format_manifest_error(
                        path,
                        ManifestError('depends', f"public addon must not depend on private addon '{dependency}'"),
                    )
                )
    except ManifestError as error:
        errors.append(format_manifest_error(path, error))

    return errors


def main() -> int:
    args = parse_args()
    manifests = iter_manifests(args.paths)
    if not manifests:
        print('No addon manifests found.')
        return 0

    private_addons = private_addon_names(manifests)
    failures: list[str] = []
    for manifest in manifests:
        for error in validate_manifest(manifest, args.odoo_version, private_addons):
            failures.append(f'{manifest}: {error}')

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    suffix = '' if len(manifests) == 1 else 's'
    print(f'Checked {len(manifests)} addon manifest{suffix}.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
