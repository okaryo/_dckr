#!/bin/sh
set -eu

rootfs=${1:?Usage: sh examples/overlay-rootfs.sh <prepared-rootfs>}
original=$(cat "$rootfs/etc/os-release")
test ! -e "$rootfs/etc/dckr-only-a"

work_dir=$(mktemp -d)
trap 'rm -f "$work_dir/input" "$work_dir/output" && rmdir "$work_dir"' EXIT
mkfifo "$work_dir/input" "$work_dir/output"

./dckr run --overlay-rootfs "$rootfs" -- /bin/busybox sh -ec '
    printf "\nDCKR_OVERLAY=container-a\n" >> /etc/os-release
    printf "a new file\n" > /etc/dckr-only-a
    /bin/busybox grep -qFx "DCKR_OVERLAY=container-a" /etc/os-release
    test -f /etc/dckr-only-a
    printf "%s\n" "Container A sees its appended line and its new file"
    IFS= read -r _
' < "$work_dir/input" > "$work_dir/output" &
first_runner=$!

exec 3>"$work_dir/input"
exec 4<"$work_dir/output"
for _ in 1 2; do
    IFS= read -r line <&4
    printf '%s\n' "$line"
done

# Read the same paths in container B while container A is still running.
./dckr run --overlay-rootfs "$rootfs" -- /bin/busybox sh -ec '
    test "$(/bin/busybox cat /etc/os-release)" = "$1"
    test ! -e /etc/dckr-only-a
    printf "%s\n" "Container B sees the original file and no new file"
' sh "$original"

test "$(cat "$rootfs/etc/os-release")" = "$original"
test ! -e "$rootfs/etc/dckr-only-a"
printf '%s\n' 'The shared lower rootfs still has its original contents'

printf '\n' >&3
wait "$first_runner"
