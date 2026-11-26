#!/bin/sh
set -eu

work_dir=$(mktemp -d)
outer_device=

cleanup() {
    if [ -n "$outer_device" ] && ip link show dev "$outer_device" >/dev/null 2>&1; then
        ip link del dev "$outer_device"
    fi
    rm -f "$work_dir/input" "$work_dir/output"
    rmdir "$work_dir"
}
trap cleanup EXIT
mkfifo "$work_dir/input" "$work_dir/output"

./dckr run --network none -- /bin/sh -ec '
    IFS= read -r device
    ip addr add 192.0.2.2/30 dev "$device"
    ip link set dev "$device" up
    printf "Inside: %s has 192.0.2.2/30\n" "$device"

    IFS= read -r _
    printf "\n%s\n" "Inside to outside"
    ping -I "$device" -c 1 -W 1 192.0.2.1
' < "$work_dir/input" > "$work_dir/output" &
runner_pid=$!

exec 3>"$work_dir/input"
exec 4<"$work_dir/output"
IFS= read -r line <&4
case "$line" in
    'outside PID='*) child_pid=${line#outside PID=} ;;
    *) printf 'Expected the outer PID, got %s\n' "$line" >&2; exit 1 ;;
esac
printf '%s\n' "$line"

name="dckr-o$$"
ip link add name "$name" type veth peer name "dckr-i$$"
outer_device=$name
# BusyBox can assign its own name to the peer, so read it before moving it.
peer=$(ip link show dev "$outer_device" | awk 'NR == 1 && split($2, links, "@") == 2 { sub(/:$/, "", links[2]); print links[2] }')
: "${peer:?could not identify the veth peer}"

ip link set dev "$peer" netns "$child_pid"
ip addr add 192.0.2.1/30 dev "$outer_device"
ip link set dev "$outer_device" up
printf 'Outside: %s has 192.0.2.1/30\n' "$outer_device"
printf '%s\n' "$peer" >&3

IFS= read -r line <&4
printf '%s\n' "$line"
printf '\n%s\n' 'Outside to inside'
ping -I "$outer_device" -c 1 -W 1 192.0.2.2

printf 'ping\n' >&3
cat <&4
wait "$runner_pid"
