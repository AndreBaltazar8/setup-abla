#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$project_root/scripts/setup.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$project_root/scripts/setup.sh" "$0"
fi

grep -Fq 'using: composite' "$project_root/action.yml"
grep -Fq 'default: 0.2.16' "$project_root/action.yml"
grep -Fq 'AndreBaltazar8/ablac/releases/download' "$project_root/scripts/setup.sh"
grep -Fq 'release checksum mismatch' "$project_root/scripts/setup.sh"
grep -Fq 'Windows is not supported' "$project_root/scripts/setup.sh"
grep -Fq 'llvm@23 lld@23' "$project_root/scripts/setup.sh"
grep -Fq 'verify-signed.sh' "$project_root/scripts/setup.sh"
grep -Fq 'signed_since=' "$project_root/scripts/setup.sh"
if grep -q python "$project_root/scripts/setup.sh"; then echo 'setup.sh uses python' >&2; exit 1; fi

# The signature check: a signed asset is accepted; tampering, a foreign key, a missing or unlisted file are refused.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
ssh-keygen -q -t ed25519 -N '' -C test -f "$work/key" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C other -f "$work/other" >/dev/null
public=$(cat "$work/key.pub")
verify() { "$project_root/scripts/verify-signed.sh" "$work/rel" abla-toolchain-x86_64-linux.tar.gz "$public" > "$work/out" 2>&1; }
release() {
    rm -rf "$work/rel"; mkdir "$work/rel"
    printf 'archive bytes\n' > "$work/rel/abla-toolchain-x86_64-linux.tar.gz"
    (cd "$work/rel" && { sha256sum abla-toolchain-x86_64-linux.tar.gz 2>/dev/null || shasum -a 256 abla-toolchain-x86_64-linux.tar.gz; } > SHA256SUMS)
    ssh-keygen -Y sign -f "${1:-$work/key}" -n abla-release "$work/rel/SHA256SUMS" >/dev/null 2>&1
}
release; verify || { cat "$work/out" >&2; exit 1; }
release; printf 'x' >> "$work/rel/abla-toolchain-x86_64-linux.tar.gz"
if verify; then echo 'accepted a tampered archive' >&2; exit 1; fi
release "$work/other"
if verify; then echo 'accepted a signature by another key' >&2; exit 1; fi
release; rm "$work/rel/SHA256SUMS.sig"
if verify; then echo 'accepted an unsigned release' >&2; exit 1; fi
release; sed -i.bak 's/abla-toolchain-x86_64-linux.tar.gz/other.tar.gz/' "$work/rel/SHA256SUMS"; rm -f "$work/rel/SHA256SUMS.bak"
if verify; then echo 'accepted a modified SHA256SUMS' >&2; exit 1; fi
grep -q REFUSED "$work/out"
printf '%s\n' 'setup-abla static checks passed'
