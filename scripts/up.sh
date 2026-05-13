#!/usr/bin/env bash
set -euo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

compose up -d

echo "Odoo $odoo_version is starting on http://localhost:${HTTP_PORT:-$(default_http_port)}"
