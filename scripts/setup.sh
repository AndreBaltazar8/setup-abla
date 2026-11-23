#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'setup-abla: %s\n' "$*" >&2
    exit 1
}

version=${SETUP_ABLA_VERSION:-}
install_dependencies=${SETUP_ABLA_INSTALL_DEPENDENCIES:-true}
token=${SETUP_ABLA_TOKEN:-}

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
    fail "version must be an exact semantic version without a leading v"
# Releases before 0.2.16 link LLVM 21; the action provides LLVM 23.
IFS=.- read -r version_major version_minor version_patch _ <<< "$version"
if ((10#$version_major == 0 && (10#$version_minor < 2 ||
    (10#$version_minor == 2 && 10#$version_patch < 16)))); then
    fail "Abla $version links LLVM 21; this action installs Abla 0.2.16 and later (LLVM 23)"
fi
case "$install_dependencies" in
    true|false) ;;
    *) fail "install-dependencies must be true or false" ;;
esac
[[ -n ${RUNNER_TOOL_CACHE:-} ]] || fail "RUNNER_TOOL_CACHE is not set"
[[ -n ${RUNNER_TEMP:-} ]] || fail "RUNNER_TEMP is not set"
[[ -n ${GITHUB_PATH:-} ]] || fail "GITHUB_PATH is not set"
[[ -n ${GITHUB_ENV:-} ]] || fail "GITHUB_ENV is not set"
[[ -n ${GITHUB_OUTPUT:-} ]] || fail "GITHUB_OUTPUT is not set"

case ${RUNNER_OS:-} in
    Linux)
        [[ ${RUNNER_ARCH:-} == X64 ]] ||
            fail "Linux ${RUNNER_ARCH:-unknown} is not published by Abla yet"
        platform=x86_64-linux
        ;;
    macOS)
        case ${RUNNER_ARCH:-} in
            ARM64) platform=arm64-macos ;;
            X64) platform=x86_64-macos ;;
            *) fail "macOS ${RUNNER_ARCH:-unknown} is not supported" ;;
        esac
        ;;
    Windows)
        case ${RUNNER_ARCH:-} in
            X64) platform=x86_64-windows ;;
            ARM64) platform=aarch64-windows ;;
            *) fail "Windows ${RUNNER_ARCH:-unknown} is not published by Abla yet" ;;
        esac
        ;;
    *)
        fail "unknown runner operating system: ${RUNNER_OS:-unset}"
        ;;
esac

# The Windows toolchain is a zip with bin/ablac.exe (tools/package-windows-toolchain.sh in ablac); the others are tar.gz with bin/ablac.
archive_extension=tar.gz
launcher_name=ablac
if [[ $RUNNER_OS == Windows ]]; then
    archive_extension=zip
    launcher_name=ablac.exe
fi
# Git Bash on a Windows runner: paths from the runner are C:\... (cygpath -u makes them POSIX for the shell, -m back to C:/...); a no-op elsewhere.
posix_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }
windows_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# Listing and unpacking the toolchain archive: tar.gz with tar; a zip (Windows) with unzip when the runner has it, else Windows's own
# bsdtar (System32\tar.exe, on every hosted Windows runner), which reads zips. Git Bash's tar is GNU tar and cannot.
system_tar() { printf '%s/System32/tar.exe\n' "$(posix_path "${SYSTEMROOT:-C:/Windows}")"; }
archive_list() {
    if [[ $archive_extension == tar.gz ]]; then tar -tzf "$1"
    elif command -v unzip >/dev/null 2>&1; then unzip -Z1 "$1"
    else "$(system_tar)" -tf "$(windows_path "$1")"; fi
}
archive_extract() {
    if [[ $archive_extension == tar.gz ]]; then tar -xzf "$1" -C "$2"
    elif command -v unzip >/dev/null 2>&1; then unzip -q "$1" -d "$2"
    else "$(system_tar)" -xf "$(windows_path "$1")" -C "$(windows_path "$2")"; fi
}

# Releases from `signed_since` on are signed: the release's SHA256SUMS carries an ssh-keygen -Y signature (namespace
# abla-release) by the project key below (release-signing.pub of AndreBaltazar8/ablac), and the toolchain archive must be
# listed there with its sha256. A signed release without a verifying signature is refused; earlier releases have only the
# checksum file beside the archive.
signed_since=0.2.67
release_public_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFG/u2ZS1IXUdXaBlNmTKgE5o42RsTwkoLs0n61RWf1+ ablac release signing'
signature_required=false
if [[ $(printf '%s\n%s\n' "$signed_since" "$version" | sort -V | head -n 1) == "$signed_since" ]]; then
    signature_required=true
fi

tool_cache=$(posix_path "${RUNNER_TOOL_CACHE%/}")
temp_root=$(posix_path "$RUNNER_TEMP")
install_root="$tool_cache/abla/$version/$platform"
case "$install_root" in
    "$tool_cache"/abla/*) ;;
    *) fail "refusing unexpected tool-cache path" ;;
esac

# Homebrew no longer bottles LLVM 23 for Intel Macs, so x86_64 installs the
# official checksum-pinned 23.1.0 Sonoma bottles (homebrew-core llvm 451e4146974a,
# lld 4c53d1f9e8fe) and links them as llvm@23 and lld@23, the prefixes the
# released launcher records.
install_macos_bottle() {
    local formula=$1 checksum=$2 token bottle
    bottle="$RUNNER_TEMP/$formula--23.1.0.sonoma.bottle.tar.gz"
    token=$(curl --fail --location --silent --show-error --retry 3 \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/$formula:pull" |
        sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    [[ -n $token ]] || fail "no registry token for the $formula bottle"
    curl --fail --location --silent --show-error --retry 3 \
        --header "Authorization: Bearer $token" \
        "https://ghcr.io/v2/homebrew/core/$formula/blobs/sha256:$checksum" -o "$bottle"
    printf '%s  %s\n' "$checksum" "$bottle" | shasum -a 256 --check ||
        fail "the $formula bottle failed its checksum"
    # Runners forbid local package paths by default; this official bottle has
    # just passed its pinned checksum check.
    env -u HOMEBREW_FORBID_PACKAGES_FROM_PATHS HOMEBREW_DEVELOPER=1 \
        brew install --ignore-dependencies "$bottle"
}

add_macos_dependencies() {
    [[ ${RUNNER_OS:-} == macOS ]] || return 0
    command -v brew >/dev/null 2>&1 ||
        fail "Homebrew is required on macOS to provide LLVM, LLD, OpenSSL, and Binaryen"

    local brew_prefix llvm_prefix lld_prefix
    brew_prefix=$(brew --prefix)
    llvm_prefix="$brew_prefix/opt/llvm@23"
    lld_prefix="$brew_prefix/opt/lld@23"
    if [[ $install_dependencies == true ]]; then
        export HOMEBREW_NO_AUTO_UPDATE=1
        local missing=()
        local package
        if [[ $platform == x86_64-macos ]]; then
            export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
            for package in openssl@3 zstd z3 binaryen; do
                if ! brew list --versions "$package" >/dev/null 2>&1; then
                    brew install --force-bottle "$package"
                fi
            done
            if [[ ! -x $llvm_prefix/bin/opt ]]; then
                install_macos_bottle llvm 0b0168dc611a9d77aaa62d094178297f8a861d647cc59c43a5dc3f76bd6eb7b2
                ln -sfn "$brew_prefix/opt/llvm" "$llvm_prefix"
            fi
            if [[ ! -x $lld_prefix/bin/wasm-ld ]]; then
                install_macos_bottle lld c8affeb82959e53875d13cd58bc459f75863f17e3d4ad68d4ca939a104fd18d5
                ln -sfn "$brew_prefix/opt/lld" "$lld_prefix"
            fi
        else
            for package in llvm@23 lld@23 openssl@3 binaryen; do
                if ! brew list --versions "$package" >/dev/null 2>&1; then
                    missing+=("$package")
                fi
            done
            if ((${#missing[@]} > 0)); then
                brew install "${missing[@]}"
            fi
        fi
    fi

    local llvm_bin lld_bin binaryen_bin
    llvm_bin="$llvm_prefix/bin"
    lld_bin="$lld_prefix/bin"
    [[ -x $llvm_bin/opt ]] ||
        fail "llvm@23 is missing; enable install-dependencies or install it first"
    [[ -x $lld_bin/wasm-ld ]] ||
        fail "lld@23 is missing; enable install-dependencies or install it first"
    binaryen_bin=$(brew --prefix binaryen 2>/dev/null)/bin ||
        fail "binaryen is missing; enable install-dependencies or install it first"
    export PATH="$llvm_bin:$lld_bin:$binaryen_bin:$PATH"
    printf '%s\n%s\n%s\n' "$llvm_bin" "$lld_bin" "$binaryen_bin" >> "$GITHUB_PATH"
}

add_linux_dependencies() {
    [[ ${RUNNER_OS:-} == Linux ]] || return 0
    local crt_path=""
    if command -v cc >/dev/null 2>&1; then
        crt_path=$(cc -print-file-name=Scrt1.o 2>/dev/null || true)
    fi
    if [[ -n $crt_path && $crt_path != Scrt1.o && -f $crt_path ]]; then
        return 0
    fi
    [[ $install_dependencies == true ]] ||
        fail "a host C toolchain is missing; enable install-dependencies or install build-essential"
    command -v apt-get >/dev/null 2>&1 ||
        fail "automatic Linux prerequisites currently require an apt-based runner"

    export DEBIAN_FRONTEND=noninteractive
    if [[ ${EUID:-$(id -u)} == 0 ]]; then
        apt-get update
        apt-get install -y --no-install-recommends build-essential
    else
        command -v sudo >/dev/null 2>&1 ||
            fail "sudo is required to install the missing Linux build prerequisites"
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends build-essential
    fi
}

cache_hit=false
if [[ -x $install_root/bin/$launcher_name && -f $install_root/.complete ]]; then
    cached_version=$("$install_root/bin/$launcher_name" --version 2>/dev/null | tr -d '\r' || true)
    if [[ $cached_version == "ablac $version" ]]; then
        cache_hit=true
    fi
fi

add_linux_dependencies
add_macos_dependencies

if [[ $cache_hit == false ]]; then
    work=$(mktemp -d "$temp_root/setup-abla.XXXXXX")
    case "$work" in
        "$temp_root"/setup-abla.*) ;;
        *) fail "refusing unexpected temporary path" ;;
    esac
    cleanup() {
        rm -rf -- "$work"
    }
    trap cleanup EXIT INT TERM

    asset="abla-toolchain-$platform.$archive_extension"
    if [[ $platform == aarch64-windows ]]; then asset=ablac-windows-arm64.zip; fi
    base="https://github.com/AndreBaltazar8/ablac/releases/download/v$version"
    curl_args=(--fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2)
    # The static checks run the whole script against a release directory on disk (file:///...); nothing else changes the source.
    if [[ ${SETUP_ABLA_TEST_BASE:-} == file:///* ]]; then
        base=$SETUP_ABLA_TEST_BASE
        curl_args=(--fail --silent --show-error --proto '=file')
    fi
    if [[ -n $token ]]; then
        printf '::add-mask::%s\n' "$token"
        curl_args+=(--header "Authorization: Bearer $token")
    fi
    curl "${curl_args[@]}" "$base/$asset" -o "$work/$asset" ||
        fail "no $asset in the Abla $version release (a platform's toolchain is published from the first release that ships it)"
    curl "${curl_args[@]}" "$base/$asset.sha256" -o "$work/$asset.sha256"

    expected=$(awk 'NR == 1 && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1) }' \
        "$work/$asset.sha256")
    [[ -n $expected ]] || fail "release checksum is malformed"
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
    else
        actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
    fi
    [[ $actual == "$expected" ]] || fail "release checksum mismatch for $asset"
    if [[ $signature_required == true ]]; then
        curl "${curl_args[@]}" "$base/SHA256SUMS" -o "$work/SHA256SUMS" ||
            fail "Abla $version is signed but has no SHA256SUMS; refusing it"
        curl "${curl_args[@]}" "$base/SHA256SUMS.sig" -o "$work/SHA256SUMS.sig" ||
            fail "Abla $version is signed but has no SHA256SUMS.sig; refusing it"
        "$(dirname -- "${BASH_SOURCE[0]}")/verify-signed.sh" "$work" "$asset" "$release_public_key" ||
            fail "the signature check of $asset failed"
    fi

    expected_root="abla-toolchain-$platform"
    while IFS= read -r entry; do
        case "$entry" in
            "$expected_root"|"$expected_root"/*) ;;
            *) fail "release archive contains an unexpected path: $entry" ;;
        esac
        case "/$entry/" in
            *'/../'*) fail "release archive contains a parent traversal" ;;
        esac
    done < <(archive_list "$work/$asset")

    mkdir -p "$work/extract" "$tool_cache/abla/$version"
    archive_extract "$work/$asset" "$work/extract"
    extracted="$work/extract/$expected_root"
    [[ -f $extracted/bin/$launcher_name ]] || fail "release archive has no $launcher_name launcher"
    [[ $RUNNER_OS == Windows ]] || [[ -x $extracted/bin/$launcher_name ]] || fail "release archive's $launcher_name is not executable"
    [[ -d $extracted/share/abla/stdlib ]] || fail "release archive has no standard library"
    [[ -d $extracted/share/abla/runtime ]] || fail "release archive has no runtime"

    if [[ -e $install_root ]]; then
        rm -rf -- "$install_root"
    fi
    mv "$extracted" "$install_root"
    printf '%s\n' "$version" > "$install_root/.complete"
fi

actual_version=$("$install_root/bin/$launcher_name" --version | tr -d '\r')
[[ $actual_version == "ablac $version" ]] ||
    fail "installed compiler reported '$actual_version' instead of 'ablac $version'"

# The runner reads GITHUB_PATH and GITHUB_ENV in its own (Windows) path form; ablac.exe finds its sysroot beside itself.
printf '%s\n' "$(windows_path "$install_root/bin")" >> "$GITHUB_PATH"
printf 'ABLA_HOME=%s\nABLA_SYSROOT=%s\n' \
    "$(windows_path "$install_root")" "$(windows_path "$install_root/share/abla")" >> "$GITHUB_ENV"
printf 'version=%s\npath=%s\ncache-hit=%s\n' \
    "$version" "$(windows_path "$install_root")" "$cache_hit" >> "$GITHUB_OUTPUT"
printf 'Installed Abla %s for %s (cache hit: %s).\n' \
    "$version" "$platform" "$cache_hit"
