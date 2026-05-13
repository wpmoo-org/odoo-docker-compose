# WPMoo Odoo Compose

Lightweight Docker Compose files for local Odoo development without Doodba. This
repository can be used standalone, or copied into a WPMoo-managed Odoo dev
environment by `@wpmoo/odoo-dev`.

## Compose files

Version-specific compose files are static and easy to inspect:

```text
docker-compose_17.0.yml
docker-compose_18.0.yml
docker-compose_19.0.yml
```

Default standalone settings use Odoo 19 on port `10019`. Image tags can be
overridden in `.env` with `ODOO_IMAGE` and `POSTGRES_IMAGE`.

## Source addons

Standalone custom addons can be placed directly under:

```text
addons/
```

WPMoo source repos are expected under:

```text
odoo/custom/src/private/
```

At container startup, `entrypoint.sh` scans WPMoo source repositories for addon
folders containing `__manifest__.py` and creates symlinks in `/mnt/wpmoo-addons`.
The static Odoo config uses:

```text
/usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons,/mnt/wpmoo-addons
```

## Usage with scripts

```bash
cp .env.example .env
./scripts/up.sh
./scripts/logs.sh
```

Open:

```text
http://localhost:10019
```

Run an Odoo shell/container command:

```bash
./scripts/shell.sh
./scripts/odoo-bin.sh --help
```

Run a module install/test cycle:

```bash
./scripts/test.sh my_module
```

Stop:

```bash
./scripts/down.sh
```

## Standalone Docker Compose usage

Without scripts, choose a version-specific compose file:

```bash
cp .env.example .env
docker compose -f docker-compose_19.0.yml up -d
```

For Odoo 18:

```bash
ODOO_VERSION=18.0 docker compose -f docker-compose_18.0.yml up -d
```

## Future reverse proxy

Traefik/reverse-proxy support is intentionally left out of the base template for
now. It can be added later as an optional compose overlay/profile without making
the local development path harder to understand.

## Notes

- Keep local `.env`, `data/`, `postgresql/`, and backups out of Git.
- For production, set real secrets and use a reverse proxy with TLS.
- For multi-version development, create a separate environment/worktree per Odoo branch.
