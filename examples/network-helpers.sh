# Read the child PID as seen by the shell configuring its network.
read_child_pid() {
    IFS= read -r line || return 1
    case "$line" in
        'outside PID='*) printf '%s\n' "${line#outside PID=}" ;;
        *) printf 'Expected the outer PID, got %s\n' "$line" >&2; return 1 ;;
    esac
}

move_veth_peer() {
    # BusyBox may assign its own name to the peer.
    peer=$(ip link show dev "$1" | awk 'NR == 1 && split($2, links, "@") == 2 { sub(/:$/, "", links[2]); print links[2] }')
    : "${peer:?could not identify the veth peer}"
    ip link set dev "$peer" netns "$2" || return 1
    printf '%s\n' "$peer"
}

configure_veth() {
    peer=$(move_veth_peer "$1" "$2")
    ip link set dev "$1" up
    nsenter -t "$2" -n ip addr add "$3" dev "$peer"
    nsenter -t "$2" -n ip link set dev "$peer" up
}
