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
grep -Fq 'platform=x86_64-windows' "$project_root/scripts/setup.sh"
grep -Fq 'platform=aarch64-windows' "$project_root/scripts/setup.sh"
# shellcheck disable=SC2016  # the pattern is the script's own text
grep -Fq 'abla-toolchain-$platform.$archive_extension' "$project_root/scripts/setup.sh"
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

# The Windows path end to end against a release directory on disk (SETUP_ABLA_TEST_BASE): a zip with bin/ablac.exe (here a script that
# prints the version) installs, is a cache hit the second time and puts its bin directory on the PATH; a tampered zip, an entry outside the
# top directory, a missing runtime or launcher, a wrong version and a missing asset are refused. Needs zip and unzip (skipped without).
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    build_zip() { # name of the zip's file in the release directory is fixed; $1 = what to break
        rm -rf "$work/tree" "$work/release"; mkdir -p "$work/tree/$top/bin" "$work/tree/$top/share/abla/stdlib" "$work/tree/$top/share/abla/runtime" "$work/release"
        printf '#!/bin/sh\necho "ablac %s"\n' "${2:-$version}" > "$work/tree/$top/bin/ablac.exe"; chmod +x "$work/tree/$top/bin/ablac.exe"
        : > "$work/tree/$top/share/abla/stdlib/entry.ab"; : > "$work/tree/$top/share/abla/runtime/runtime.c"
        case ${1:-} in
            no-launcher) rm "$work/tree/$top/bin/ablac.exe" ;;
            no-runtime) rm -r "$work/tree/$top/share/abla/runtime" ;;
            stray) echo x > "$work/tree/stray.txt" ;;
        esac
        (cd "$work/tree" && zip -q -r -X "$work/release/$asset" .)
        (cd "$work/release" && { sha256sum "$asset" 2>/dev/null || shasum -a 256 "$asset"; } > "$asset.sha256")
    }
    run_setup() { # fresh tool cache unless $1 = keep
        [[ ${1:-} == keep ]] || { rm -rf "$work/cache"; mkdir -p "$work/cache"; }
        mkdir -p "$work/temp"; : > "$work/github-path"; : > "$work/github-env"; : > "$work/github-output"
        RUNNER_OS=Windows RUNNER_ARCH="$arch" RUNNER_TOOL_CACHE="$work/cache" RUNNER_TEMP="$work/temp" GITHUB_PATH="$work/github-path" \
            GITHUB_ENV="$work/github-env" GITHUB_OUTPUT="$work/github-output" SETUP_ABLA_VERSION="$version" \
            SETUP_ABLA_TEST_BASE="file://$work/release" "$project_root/scripts/setup.sh" > "$work/setup.out" 2>&1
    }
    refused() { # label needle
        if run_setup; then echo "setup-abla accepted: $1" >&2; exit 1; fi
        grep -Fq -- "$2" "$work/setup.out" || { echo "setup-abla's refusal of $1 does not say '$2':" >&2; cat "$work/setup.out" >&2; exit 1; }
    }
    for arch in X64 ARM64; do
        case $arch in
            X64) platform=x86_64-windows; asset=abla-toolchain-x86_64-windows.zip; signed_version=0.2.67 ;;
            ARM64) platform=aarch64-windows; asset=ablac-windows-arm64.zip; signed_version=0.2.69 ;;
        esac
        top=abla-toolchain-$platform
        version=0.2.66
        build_zip; run_setup || { cat "$work/setup.out" >&2; exit 1; }
        grep -Fxq "$work/cache/abla/$version/$platform/bin" "$work/github-path"
        grep -Fxq "ABLA_SYSROOT=$work/cache/abla/$version/$platform/share/abla" "$work/github-env"
        grep -Fxq 'cache-hit=false' "$work/github-output"
        [[ -d $work/cache/abla/$version/$platform/share/abla/stdlib ]]
        run_setup keep || { cat "$work/setup.out" >&2; exit 1; }
        grep -Fxq 'cache-hit=true' "$work/github-output"
        build_zip no-launcher; refused 'a zip without bin/ablac.exe' 'no ablac.exe launcher'
        build_zip no-runtime; refused 'a zip without the runtime' 'no runtime'
        build_zip stray; refused 'a zip with an entry outside the top directory' 'unexpected path'
        build_zip '' 9.9.9; refused 'a compiler reporting another version' "instead of 'ablac $version'"
        build_zip; printf 'x' >> "$work/release/$asset"; refused 'a tampered zip' 'checksum mismatch'
        rm -rf "$work/release"; mkdir "$work/release"; refused 'a release without the Windows asset' "no $asset"
        version=$signed_version; build_zip; refused 'a Windows release without its signature manifest' 'SHA256SUMS'
    done
else
    echo 'setup-abla: skipped the Windows end-to-end check (zip or unzip is not installed)'
fi
printf '%s\n' 'setup-abla static checks passed'
