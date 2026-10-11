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
        fail "Windows is not supported by the released Abla compiler yet"
        ;;
    *)
        fail "unknown runner operating system: ${RUNNER_OS:-unset}"
        ;;
esac

tool_cache=${RUNNER_TOOL_CACHE%/}
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
        /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
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
if [[ -x $install_root/bin/ablac && -f $install_root/.complete ]]; then
    cached_version=$("$install_root/bin/ablac" --version 2>/dev/null || true)
    if [[ $cached_version == "ablac $version" ]]; then
        cache_hit=true
    fi
fi

add_linux_dependencies
add_macos_dependencies

if [[ $cache_hit == false ]]; then
    work=$(mktemp -d "$RUNNER_TEMP/setup-abla.XXXXXX")
    case "$work" in
        "$RUNNER_TEMP"/setup-abla.*) ;;
        *) fail "refusing unexpected temporary path" ;;
    esac
    cleanup() {
        rm -rf -- "$work"
    }
    trap cleanup EXIT INT TERM

    asset="abla-toolchain-$platform.tar.gz"
    base="https://github.com/AndreBaltazar8/ablac/releases/download/v$version"
    curl_args=(--fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2)
    if [[ -n $token ]]; then
        printf '::add-mask::%s\n' "$token"
        curl_args+=(--header "Authorization: Bearer $token")
    fi
    curl "${curl_args[@]}" "$base/$asset" -o "$work/$asset"
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

    expected_root="abla-toolchain-$platform"
    while IFS= read -r entry; do
        case "$entry" in
            "$expected_root"|"$expected_root"/*) ;;
            *) fail "release archive contains an unexpected path: $entry" ;;
        esac
        case "/$entry/" in
            *'/../'*) fail "release archive contains a parent traversal" ;;
        esac
    done < <(tar -tzf "$work/$asset")

    mkdir -p "$work/extract" "$tool_cache/abla/$version"
    tar -xzf "$work/$asset" -C "$work/extract"
    extracted="$work/extract/$expected_root"
    [[ -x $extracted/bin/ablac ]] || fail "release archive has no ablac launcher"
    [[ -d $extracted/share/abla/stdlib ]] || fail "release archive has no standard library"
    [[ -d $extracted/share/abla/runtime ]] || fail "release archive has no runtime"

    if [[ -e $install_root ]]; then
        rm -rf -- "$install_root"
    fi
    mv "$extracted" "$install_root"
    printf '%s\n' "$version" > "$install_root/.complete"
fi

actual_version=$("$install_root/bin/ablac" --version)
[[ $actual_version == "ablac $version" ]] ||
    fail "installed compiler reported '$actual_version' instead of 'ablac $version'"

printf '%s\n' "$install_root/bin" >> "$GITHUB_PATH"
printf 'ABLA_HOME=%s\nABLA_SYSROOT=%s\n' \
    "$install_root" "$install_root/share/abla" >> "$GITHUB_ENV"
printf 'version=%s\npath=%s\ncache-hit=%s\n' \
    "$version" "$install_root" "$cache_hit" >> "$GITHUB_OUTPUT"
printf 'Installed Abla %s for %s (cache hit: %s).\n' \
    "$version" "$platform" "$cache_hit"
