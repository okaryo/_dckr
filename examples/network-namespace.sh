#!/bin/sh
set -eu

printf '%s\n' 'Interfaces and IPv4 routes in the shared network namespace'
./dckr run -- /bin/sh -ec '
    ip link show | grep -E "^[0-9]+:"
    ip -4 route show
'

printf '\n%s\n' 'Interfaces and IPv4 routes in the new network namespace'
./dckr run --network none -- /bin/sh -ec '
    ip link show | grep -E "^[0-9]+:"
    ip -4 route show

    printf "\n%s\n" "Enabling loopback in the new namespace"
    ip link set dev lo up
    ip -4 addr show dev lo
    ping -c 1 -W 1 127.0.0.1
'
