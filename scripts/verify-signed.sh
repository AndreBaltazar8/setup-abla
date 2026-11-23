#!/usr/bin/env bash
# Verifies that a downloaded release asset is the one the Abla project signed: the signature of the release's SHA256SUMS
# (ssh-keygen -Y sign, namespace abla-release) must verify against the project's public key, and SHA256SUMS must list
# the asset with the sha256 of the file. Fails closed.
#
#   verify-signed.sh WORKDIR ASSET PUBLIC_KEY_LINE
#
# WORKDIR holds the downloaded SHA256SUMS and SHA256SUMS.sig and the ASSET itself.
set -euo pipefail

work=${1:?usage: verify-signed.sh WORKDIR ASSET PUBLIC_KEY_LINE}
asset=${2:?}
key_line=${3:?}
fail() { printf 'setup-abla: REFUSED: %s\n' "$*" >&2; exit 1; }

[[ -f $work/SHA256SUMS && -f $work/SHA256SUMS.sig ]] || fail "the release has no signed SHA256SUMS"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is needed to verify the release signature"
# allowed signers: principal, key type, key (the key's comment is dropped).
printf 'ablac-release %s %s\n' "$(awk '{ print $1 }' <<< "$key_line")" "$(awk '{ print $2 }' <<< "$key_line")" > "$work/allowed-signers"
ssh-keygen -Y verify -f "$work/allowed-signers" -I ablac-release -n abla-release -s "$work/SHA256SUMS.sig" \
    < "$work/SHA256SUMS" > "$work/verify.log" 2>&1 || fail "the signature of SHA256SUMS does not verify"
signed=$(awk -v name="$asset" '$2 == name { print tolower($1); exit }' "$work/SHA256SUMS")
[[ $signed =~ ^[0-9a-f]{64}$ ]] || fail "$asset is not listed in the signed SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
else
    actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
fi
[[ $actual == "$signed" ]] || fail "$asset does not match the signed checksum"
