#!/bin/sh
set -eu

parent=${1:?Usage: sh examples/cgroup-memory.sh <cgroup-v2-parent>}
work_dir=$(mktemp -d)
trial=

cleanup() {
    rm -f "$work_dir/worker.go" "$work_dir/worker"
    rmdir "$work_dir"
    if [ -n "$trial" ]; then
        for group in "$trial/limited" "$trial/baseline" "$trial"; do
            if [ -d "$group" ]; then
                rmdir "$group"
            fi
        done
    fi
}
trap cleanup EXIT

cat > "$work_dir/worker.go" <<'GO'
package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	const size = 64 << 20
	payload := make([]byte, size)
	pageSize := os.Getpagesize()
	for offset := 0; offset < len(payload); offset += pageSize {
		payload[offset] = 1
	}
	fmt.Println("Touched 64 MiB of memory")
	runtime.KeepAlive(payload)
}
GO
CGO_ENABLED=0 go build -o "$work_dir/worker" "$work_dir/worker.go"

trial=$(mktemp -d "$parent/dckr-memory.XXXXXX")
baseline="$trial/baseline"
limited="$trial/limited"
printf '+memory\n' > "$trial/cgroup.subtree_control"
mkdir "$baseline" "$limited"
printf '33554432\n' > "$limited/memory.max"
for group in "$baseline" "$limited"; do
    if [ -f "$group/memory.swap.max" ]; then
        printf '0\n' > "$group/memory.swap.max"
    fi
done

run_workload() {
    printf '\n%s memory.max = ' "${1##*/}"
    cat "$1/memory.max"
    run_status=0
    ./dckr run --cgroup "$1" -- "$work_dir/worker" || run_status=$?
    printf 'dckr exit status = %s\n' "$run_status"
    awk '$1 == "max" || $1 == "oom" || $1 == "oom_kill"' "$1/memory.events"
}

run_workload "$baseline"
test "$run_status" -eq 0
run_workload "$limited"
test "$run_status" -ne 0
awk '$1 == "oom_kill" { killed = $2 > 0 } END { exit !killed }' "$limited/memory.events"
