#!/bin/sh
set -eu

parent=${1:?Usage: sh examples/cgroup-cpu.sh <cgroup-v2-parent>}
trial=$(mktemp -d "$parent/dckr-cpu.XXXXXX")
baseline="$trial/baseline"
limited="$trial/limited"
trap 'rmdir "$limited" "$baseline" "$trial" 2>/dev/null || true' EXIT

printf '+cpu\n' > "$trial/cgroup.subtree_control"
mkdir "$baseline" "$limited"
printf '25000 100000\n' > "$limited/cpu.max"

run_workload() {
    printf '\n%s cpu.max = ' "${1##*/}"
    cat "$1/cpu.max"
    ./dckr run --cgroup "$1" -- /bin/sh -ec '
        cat /proc/self/cgroup
        yes >/dev/null &
        worker=$!
        sleep 2
        kill "$worker"
        wait "$worker" 2>/dev/null || :
    '
    awk '$1 == "usage_usec" || $1 == "nr_throttled" || $1 == "throttled_usec"' "$1/cpu.stat"
}

run_workload "$baseline"
run_workload "$limited"
awk '$1 == "nr_throttled" { throttled = $2 > 0 } END { exit !throttled }' "$limited/cpu.stat"
