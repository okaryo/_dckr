#!/bin/sh
set -eu

work_dir=$(mktemp -d)
bridge=
first_link=
second_link=

cleanup() {
    for link in "$first_link" "$second_link" "$bridge"; do
        if [ -n "$link" ] && ip link show dev "$link" >/dev/null 2>&1; then
            ip link del dev "$link"
        fi
    done
    rm -f "$work_dir/first.input" "$work_dir/first.output" "$work_dir/second.input" "$work_dir/second.output"
    rmdir "$work_dir"
}
trap cleanup EXIT

read_child_pid() {
    IFS= read -r line < "$1" || return 1
    case "$line" in
        'outside PID='*) printf '%s\n' "${line#outside PID=}" ;;
        *) printf 'Expected the outer PID, got %s\n' "$line" >&2; return 1 ;;
    esac
}

configure_veth() {
    # Read the actual peer name because BusyBox may assign a name of its own.
    peer=$(ip link show dev "$1" | awk 'NR == 1 && split($2, links, "@") == 2 { sub(/:$/, "", links[2]); print links[2] }')
    : "${peer:?could not identify the veth peer}"
    ip link set dev "$peer" netns "$2"
    ip link set dev "$1" up
    nsenter -t "$2" -n ip addr add "$3" dev "$peer"
    nsenter -t "$2" -n ip link set dev "$peer" up
}

mkfifo "$work_dir/first.input" "$work_dir/first.output" "$work_dir/second.input" "$work_dir/second.output"

# The two shells stay alive until the outer script releases them.
./dckr run --network none -- /bin/sh -ec 'IFS= read -r _' < "$work_dir/first.input" > "$work_dir/first.output" &
first_runner=$!
exec 3>"$work_dir/first.input"
first_pid=$(read_child_pid "$work_dir/first.output")

./dckr run --network none -- /bin/sh -ec 'IFS= read -r _' < "$work_dir/second.input" > "$work_dir/second.output" 3>&- &
second_runner=$!
exec 4>"$work_dir/second.input"
second_pid=$(read_child_pid "$work_dir/second.output")

name="dckr-b$$"
ip link add name "$name" type bridge
bridge=$name
ip link set dev "$bridge" up

name="dckr-a$$"
ip link add name "$name" type veth peer name "dckr-i$$"
first_link=$name
configure_veth "$first_link" "$first_pid" 192.0.2.1/30

name="dckr-c$$"
ip link add name "$name" type veth peer name "dckr-j$$"
second_link=$name
configure_veth "$second_link" "$second_pid" 192.0.2.2/30

printf '%s\n' 'Before attaching the veth links to the bridge'
if nsenter -t "$first_pid" -n ping -c 1 -W 1 192.0.2.2; then
    printf '%s\n' 'Unexpected reply before the bridge was connected' >&2
    exit 1
fi

ip link set dev "$first_link" master "$bridge"
ip link set dev "$second_link" master "$bridge"
printf '\n%s\n' 'After attaching both veth links to the bridge'
nsenter -t "$first_pid" -n ping -c 1 -W 2 192.0.2.2
nsenter -t "$second_pid" -n ping -c 1 -W 2 192.0.2.1

printf '\n' >&3
printf '\n' >&4
wait "$first_runner"
wait "$second_runner"
