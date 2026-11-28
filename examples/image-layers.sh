#!/bin/sh
set -eu

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

mkdir -p "$work_dir/base/etc" "$work_dir/base/cache"
printf 'NAME="base layer"\n' > "$work_dir/base/etc/os-release"
printf 'legacy configuration\n' > "$work_dir/base/etc/legacy.conf"
printf 'old cache\n' > "$work_dir/base/cache/old"
tar -cf "$work_dir/base.tar" -C "$work_dir/base" .

mkdir -p "$work_dir/upper/etc" "$work_dir/upper/cache"
printf 'NAME="upper layer"\n' > "$work_dir/upper/etc/os-release"
: > "$work_dir/upper/etc/.wh.legacy.conf"
printf 'new cache\n' > "$work_dir/upper/cache/new"
: > "$work_dir/upper/cache/.wh..wh..opq"
tar -cf "$work_dir/upper.tar" -C "$work_dir/upper" \
    etc/os-release etc/.wh.legacy.conf cache/new cache/.wh..wh..opq

./dckr image unpack "$work_dir/rootfs" "$work_dir/base.tar" "$work_dir/upper.tar"
grep -Fx 'NAME="upper layer"' "$work_dir/rootfs/etc/os-release"
test ! -e "$work_dir/rootfs/etc/legacy.conf"
test ! -e "$work_dir/rootfs/cache/old"
test -z "$(find "$work_dir/rootfs" -name '.wh.*' -print)"
printf '%s\n' 'Cache files in the merged rootfs'
ls "$work_dir/rootfs/cache"
grep -Fx 'new cache' "$work_dir/rootfs/cache/new"
