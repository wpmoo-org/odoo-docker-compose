#!/usr/bin/env python3
import argparse
import ast
from pathlib import Path
import sys


SKIP_DIRS = {'.git', '.mypy_cache', '.pytest_cache', '.ruff_cache', '__pycache__', 'node_modules'}


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
        raise ValueError(f'manifest must be a Python literal dict: {error}') from error

    if not isinstance(parsed, dict):
        raise ValueError('manifest must be a Python literal dict')
    return parsed


def require_string(manifest: dict, key: str) -> str:
    value = manifest.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'{key} must be a non-empty string')
    return value


def require_string_list(manifest: dict, key: str, required: bool = False) -> None:
    value = manifest.get(key)
    if value is None:
        if required:
            raise ValueError(f'{key} must be a list of non-empty strings')
        return
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ValueError(f'{key} must be a list of non-empty strings')


def validate_manifest(path: Path, odoo_version: str) -> list[str]:
    errors: list[str] = []
    try:
        manifest = read_manifest(path)
        version = require_string(manifest, 'version')
        require_string(manifest, 'license')
        require_string_list(manifest, 'depends', required=True)
        require_string_list(manifest, 'data')
        require_string_list(manifest, 'demo')

        if not version.startswith(f'{odoo_version}.'):
            errors.append(f'version must start with {odoo_version}.')
        for key in ('installable', 'application'):
            if key in manifest and not isinstance(manifest[key], bool):
                errors.append(f'{key} must be a boolean when present')
    except ValueError as error:
        errors.append(str(error))

    return errors


def main() -> int:
    args = parse_args()
    manifests = iter_manifests(args.paths)
    if not manifests:
        print('No addon manifests found.')
        return 0

    failures: list[str] = []
    for manifest in manifests:
        for error in validate_manifest(manifest, args.odoo_version):
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
