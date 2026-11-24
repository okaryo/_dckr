#!/bin/sh
set -eu

work_dir=$(mktemp -d)
trap 'rm -f "$work_dir/input" "$work_dir/output" && rmdir "$work_dir"' EXIT
mkfifo "$work_dir/input" "$work_dir/output"

# Keep PID 1 alive until the outer shell has found its background worker.
./dckr run -- /bin/sh -ec '
    sleep 60 &
    printf "Inside the namespace, shell PID=%s and sleep PID=%s\n" "$$" "$!"
    read -r _
    exit 0
' < "$work_dir/input" > "$work_dir/output" &
runner_pid=$!

exec 3>"$work_dir/input"
exec 4<"$work_dir/output"

# The launcher and the inner shell can print in either order.
init_pid=
for _ in 1 2; do
    IFS= read -r line <&4
    printf '%s\n' "$line"
    case "$line" in
        'outside PID='*) init_pid=${line#outside PID=} ;;
    esac
done
: "${init_pid:?dckr did not report the outer PID}"

# The worker is the only child of the inner shell at this point.
sleep_pid=$(ps -o pid,ppid | awk -v parent="$init_pid" '$2 == parent { print $1 }')
: "${sleep_pid:?could not find the worker in the outer namespace}"
test -d "/proc/$sleep_pid"
printf 'Before PID 1 exits, outer /proc/%s exists\n' "$sleep_pid"

printf 'exit\n' >&3
wait "$runner_pid"

if [ -d "/proc/$sleep_pid" ]; then
    printf 'Worker PID %s is still visible after PID 1 exited\n' "$sleep_pid" >&2
    exit 1
fi
printf 'After PID 1 exits, outer /proc/%s is gone\n' "$sleep_pid"
