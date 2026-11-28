#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
dependencies="$repo_root/Dependencies"
destination="$dependencies/OpenSSL.xcframework"
receipt="$dependencies/OpenSSL.xcframework.sha256"
version=3.6.5000
sha256=f50188506490c643715489217d32e458d06cee5579399ff616f0ce2038169fea

if [ -d "$destination" ]; then
    if [ -f "$destination/Info.plist" ] && [ -f "$receipt" ] &&
        [ "$(cat "$receipt")" = "$sha256" ]; then
        echo "OpenSSL $version is already prepared."
        exit 0
    fi
    echo "OpenSSL already exists without the expected receipt: $destination" >&2
    echo "Move that directory aside before preparing the pinned dependency." >&2
    exit 1
fi

mkdir -p "$dependencies"
work_dir="$(mktemp -d "$dependencies/.openssl.XXXXXX")"
# Failed extraction remains in its staging directory for diagnosis. Never
# replace an existing framework or publish an incompletely extracted one.
trap 'rm -f "$work_dir/OpenSSL.xcframework.zip"; rmdir "$work_dir" 2>/dev/null || true' EXIT
archive="$work_dir/OpenSSL.xcframework.zip"
curl --fail --location --retry 3 --connect-timeout 30 --max-time 300 \
    --output "$archive" \
    "https://github.com/krzyzanowskim/OpenSSL/releases/download/$version/OpenSSL.xcframework.zip"
printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$work_dir"
test -f "$work_dir/OpenSSL.xcframework/Info.plist"
mv "$work_dir/OpenSSL.xcframework" "$destination"
printf '%s\n' "$sha256" > "$receipt"
