#!/bin/sh
set -eu

# Run the router setup in a new network namespace with its own procfs mount.
exec ./dckr run --network none -- /bin/sh -eus <<'ROUTER'
. ./examples/network-helpers.sh

work_dir=$(mktemp -d)
trap 'rm -f "$work_dir/client.input" "$work_dir/client.output" "$work_dir/upstream.input" "$work_dir/upstream.output" "$work_dir/xtables.lock" && rmdir "$work_dir"' EXIT
export XTABLES_LOCKFILE="$work_dir/xtables.lock"
mkfifo "$work_dir/client.input" "$work_dir/client.output" "$work_dir/upstream.input" "$work_dir/upstream.output"

./dckr run --network none -- /bin/sh -ec 'IFS= read -r _' < "$work_dir/client.input" > "$work_dir/client.output" &
client_runner=$!
exec 3>"$work_dir/client.input"
client_pid=$(read_child_pid < "$work_dir/client.output")

./dckr run --network none -- /bin/sh -ec 'IFS= read -r _' < "$work_dir/upstream.input" > "$work_dir/upstream.output" 3>&- &
upstream_runner=$!
exec 4>"$work_dir/upstream.input"
upstream_pid=$(read_child_pid < "$work_dir/upstream.output")

printf '0\n' > /proc/sys/net/ipv4/ip_forward

ip link add name dckr-br type bridge
ip addr add 192.0.2.1/30 dev dckr-br
ip link set dev dckr-br up
ip link add name dckr-lan type veth peer name dckr-client
configure_veth dckr-lan "$client_pid" 192.0.2.2/30
ip link set dev dckr-lan master dckr-br

ip link add name dckr-uplink type veth peer name dckr-upstream
configure_veth dckr-uplink "$upstream_pid" 198.51.100.2/30
ip addr add 198.51.100.1/30 dev dckr-uplink

client_ping() {
    nsenter -t "$client_pid" -n ping -c 1 -W 1 "$1"
}

expect_no_reply() {
    printf '\n%s\n' "$1"
    if client_ping 198.51.100.2; then
        printf '%s\n' 'Unexpected reply from upstream' >&2
        exit 1
    fi
}

printf '%s\n' 'The client can reach the bridge gateway'
client_ping 192.0.2.1
expect_no_reply 'No default route in the client'

nsenter -t "$client_pid" -n ip route add default via 192.0.2.1
expect_no_reply 'Default route configured, IPv4 forwarding off'

printf '1\n' > /proc/sys/net/ipv4/ip_forward
expect_no_reply 'IPv4 forwarding on, upstream has no return route'

printf '\n%s\n' 'IPv4 forwarding on, upstream has an explicit return route'
nsenter -t "$upstream_pid" -n ip route add 192.0.2.0/30 via 198.51.100.1
client_ping 198.51.100.2
nsenter -t "$upstream_pid" -n ip route del 192.0.2.0/30 via 198.51.100.1

printf '\n%s\n' 'IPv4 forwarding and source NAT, upstream has no route to the client subnet'
iptables -t nat -A POSTROUTING -s 192.0.2.0/30 -d 198.51.100.2/32 -o dckr-uplink -j SNAT --to-source 198.51.100.1
client_ping 198.51.100.2
nat_counters=$(iptables -t nat -vnL POSTROUTING)
printf '%s\n' "$nat_counters"
printf '%s\n' "$nat_counters" | awk '$3 == "SNAT" { matched = $1 > 0 } END { exit !matched }'

printf '\n' >&3
printf '\n' >&4
wait "$client_runner"
wait "$upstream_runner"
ROUTER
