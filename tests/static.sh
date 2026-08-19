#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$project_root/scripts/setup.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$project_root/scripts/setup.sh" "$0"
fi

grep -Fq 'using: composite' "$project_root/action.yml"
grep -Fq 'default: 0.2.10' "$project_root/action.yml"
grep -Fq 'AndreBaltazar8/ablac/releases/download' "$project_root/scripts/setup.sh"
grep -Fq 'release checksum mismatch' "$project_root/scripts/setup.sh"
grep -Fq 'Windows is not supported' "$project_root/scripts/setup.sh"
printf '%s\n' 'setup-abla static checks passed'
