# dckr

`dckr` is a small Go container runtime project for learning how Docker uses Linux kernel features. The experiments cover process visibility, filesystem isolation, CPU and memory limits, and container networking. The final stage builds a root filesystem from image layers and gives each container its own writable layer.

## Scope

The runtime starts with a foreground `run` command and grows one experiment at a time. Dockerfile builds, registry access, daemon-based management, and rootless execution are optional follow-ups.

## Getting started

Run the experiments on Linux with Go installed. From the repository root of a Linux VM, build `dckr` and run the process visibility experiment with the privileges needed to create namespaces and mount procfs.

```sh
go build -o dckr .
sudo ./dckr run -- /bin/sh -c 'ps -o pid,comm; echo "inside PID=$$"'
```

`dckr` starts a copy of itself in new PID and mount namespaces. That child mounts a fresh procfs at `/proc` and then replaces itself with the requested command. `ps` reads this `/proc` and lists the shell at PID `1` and the `ps` process itself. `outside PID` is the shell's PID as seen by the parent `dckr` process.

### PID 1 exit

After building `dckr` on Linux, run the example from the repository root.

```sh
sudo sh examples/pid1-exit.sh
```

The inner shell starts a background `sleep` and waits for input. The outer shell finds that worker in its own `/proc`, tells PID `1` to exit, then checks the same worker's entry again. Linux terminates the remaining processes in the inner PID namespace when its PID `1` exits.

### Root filesystem

Pass `--rootfs` to use an unpacked directory as `/` for the requested command. The directory needs a `/proc` mount point, the command and any libraries it needs, and an `/etc/os-release` file for this experiment. For example, with BusyBox installed at `./rootfs/bin/busybox`, compare the same path from both sides.

```sh
cat /etc/os-release
sudo ./dckr run --rootfs ./rootfs -- /bin/busybox cat /etc/os-release
```

The child bind-mounts the directory onto itself, switches to it with `pivot_root`, and detaches the old root. It then mounts procfs and looks up the command from under the new `/`.

### CPU limits with cgroup v2

`--cgroup <directory>` starts a child directly in an existing cgroup v2 leaf. This uses `CLONE_INTO_CGROUP`, which requires Linux 5.7 or later. The caller prepares the cgroup and its limits.

To compare two CPU quotas on Linux, give the example a writable cgroup v2 parent with the `cpu` controller enabled for its children.

```sh
sudo sh examples/cgroup-cpu.sh /path/to/cgroup-parent
```

The script runs the same workload twice. `max 100000` leaves the baseline without a local CPU quota. `25000 100000` gives the entire limited group up to 25 ms of CPU time every 100 ms, equivalent to one quarter of one CPU under sustained load. In `cpu.stat`, `usage_usec` reports CPU time used and `nr_throttled` counts the times the group was throttled.

### Docker Desktop on macOS

Run the experiments from the repository root using a temporary ARM64 Go container in Docker Desktop's Linux VM. The container receives the source files and example scripts over standard input. `SYS_ADMIN` allows `dckr` to create namespaces, mount procfs, and switch the root mount. The CPU example mounts a writable view of the temporary container's cgroup subtree and moves the launcher into its own child cgroup before enabling the `cpu` controller in its parent.

```sh
tar -cf - go.mod main.go examples/pid1-exit.sh examples/cgroup-cpu.sh |
  docker --context desktop-linux run --rm -i --platform linux/arm64 \
    --network none --cap-drop ALL --cap-add SYS_ADMIN --cgroupns private \
    docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
      cd "$(mktemp -d)"
      tar -xf -
      go build -o dckr .
      ./dckr run -- /bin/sh -c "ps -o pid,comm; echo inside PID=\$\$"
      sh examples/pid1-exit.sh

      mkdir -p rootfs/bin rootfs/etc rootfs/lib rootfs/proc
      cp /bin/busybox rootfs/bin/
      cp -L /lib/ld-musl-aarch64.so.1 rootfs/lib/
      printf "NAME=\"dckr rootfs\"\n" > rootfs/etc/os-release
      sed -n "s/^NAME=/Outside NAME=/p" /etc/os-release
      ./dckr run --rootfs rootfs -- /bin/busybox cat /etc/os-release

      tree=$(mktemp -d)
      mount -t cgroup2 none "$tree"
      mkdir "$tree/launcher"
      printf "%s\n" "$$" > "$tree/launcher/cgroup.procs"
      printf "+cpu\n" > "$tree/cgroup.subtree_control"
      sh examples/cgroup-cpu.sh "$tree"
    '
```

Here, the outer PID namespace is the temporary Go container's namespace. See [TODO.md](TODO.md) for recorded results and the full roadmap.

The project follows the workflow in [LEARNING_PROJECT.md](LEARNING_PROJECT.md).
