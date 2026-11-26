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

### Memory limits with cgroup v2

Give the example a writable cgroup v2 parent with the `memory` controller enabled for its children. The script uses Go to build the worker, so `go` must be available on its `PATH`.

```sh
sudo sh examples/cgroup-memory.sh /path/to/cgroup-parent
```

The worker writes to every page in a 64 MiB buffer. The baseline uses the default `memory.max` of `max` and inherits any ancestor limits. The limited group sets `memory.max` to 32 MiB. Both groups set their swap limit to zero when the swap controller file is available. When Linux cannot reclaim enough memory to satisfy an allocation in the limited group, the out-of-memory killer terminates the worker. `dckr` reports `signal: killed` and exits with status `1`. The increase in `oom_kill` in `memory.events` records the reason.

### Network namespaces

`--network none` launches the child in a new network namespace using `CLONE_NEWNET`. By default, `dckr run` uses the caller's network namespace. On Linux with `ip` and `ping` installed, compare the interfaces and IPv4 routes from both runs.

```sh
sudo sh examples/network-namespace.sh
```

The example shows the new namespace's initial state, then brings up its loopback interface (`lo`) and pings `127.0.0.1`. Some kernel configurations also create unconfigured tunnel devices such as `tunl0` in each namespace.

### Connecting namespaces with veth

A veth pair has two connected virtual Ethernet interfaces. The example keeps one interface outside and moves its peer to the `dckr` child's network namespace using the child's outer PID. It gives the two interfaces addresses in `192.0.2.0/30`, brings both links up, and pings across the link in both directions.

```sh
sudo sh examples/veth.sh
```

Run this experiment in a Linux VM or use the Docker Desktop commands below. The example assigns `192.0.2.1/30` outside and `192.0.2.2/30` inside.

### Docker Desktop on macOS

Run the experiments from the repository root using a temporary ARM64 Go container in Docker Desktop's Linux VM. The container receives the source files and example scripts over standard input. `SYS_ADMIN` allows `dckr` to create namespaces, mount procfs, and switch the root mount. The cgroup experiments use a writable view of the temporary container's cgroup subtree. The launcher moves into its own child cgroup before enabling `cpu` and `memory` in its parent.

```sh
tar -cf - go.mod main.go examples/pid1-exit.sh examples/cgroup-cpu.sh examples/cgroup-memory.sh |
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
      printf "+cpu +memory\n" > "$tree/cgroup.subtree_control"
      sh examples/cgroup-cpu.sh "$tree"
      sh examples/cgroup-memory.sh "$tree"
    '
```

Here, the outer PID namespace is the temporary Go container's namespace. See [TODO.md](TODO.md) for recorded results and the full roadmap.

#### Network namespace experiment

Run these examples in a temporary Go container with its own network namespace. The first veth pair adds a comparison interface and route for the loopback experiment. The second example creates its own pair to connect to the child. `NET_ADMIN` allows the examples to configure interfaces, and `NET_RAW` allows them to run `ping`.

```sh
tar -cf - go.mod main.go examples/network-namespace.sh examples/veth.sh |
  docker --context desktop-linux run --rm -i --platform linux/arm64 \
    --network none --cap-drop ALL --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add NET_RAW \
    docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
      cd "$(mktemp -d)"
      tar -xf -
      go build -o dckr .
      ip link add name dckr-outer type veth peer name dckr-peer
      ip addr add 192.0.2.1/24 dev dckr-outer
      ip link set dev dckr-outer up
      sh examples/network-namespace.sh
      ip link del dev dckr-outer
      sh examples/veth.sh
    '
```

The project follows the workflow in [LEARNING_PROJECT.md](LEARNING_PROJECT.md).
