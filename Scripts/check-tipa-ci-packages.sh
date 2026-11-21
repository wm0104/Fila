#!/usr/bin/env bash
# CI's complete artifact is one TIPA, its matching symbols, and their checksums.
set -euo pipefail
export LC_ALL=C

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <package-directory> <version>" >&2
    exit 64
fi
packages="$1"
version="$2"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] || {
    echo "error: invalid TIPA version" >&2
    exit 64
}
[[ -d "$packages" && ! -L "$packages" ]] || {
    echo "error: missing or linked package directory" >&2
    exit 66
}
fail() { echo "error: TIPA outputs: $*" >&2; exit 65; }
tipa="Fila_${version}.tipa"
symbols="Fila_${version}_dSYMs.zip"
shopt -s nullglob dotglob
entries=("$packages"/*)
[[ "${#entries[@]}" -eq 3 ]] || fail "expected exactly one TIPA, dSYMs and SHA256SUMS"
for name in "$tipa" "$symbols" SHA256SUMS; do
    [[ -f "$packages/$name" && ! -L "$packages/$name" && -s "$packages/$name" ]] \
        || fail "missing, empty or linked $name"
done

tipa_seen=0
symbols_seen=0
while IFS= read -r line || [[ -n "$line" ]]; do
    hash="${line%% *}"
    [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid checksum entry"
    if [[ "$line" == "$hash  $tipa" && "$tipa_seen" -eq 0 ]]; then
        tipa_seen=1
    elif [[ "$line" == "$hash  $symbols" && "$symbols_seen" -eq 0 ]]; then
        symbols_seen=1
    else
        fail "unexpected or duplicate checksum entry"
    fi
done < "$packages/SHA256SUMS"
[[ "$tipa_seen" -eq 1 && "$symbols_seen" -eq 1 ]] || fail "incomplete checksums"
echo "Verified single-TIPA output layout for $version"
