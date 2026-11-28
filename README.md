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

### Connecting two namespaces with a bridge

A Linux bridge acts as an Ethernet switch. Each child has its own veth pair. The outer end of each pair becomes a port on the same bridge with `ip link set dev <interface> master <bridge>`. The bridge forwards Ethernet frames between the ports without an IPv4 address in this experiment.

Run this example in a Linux VM with `ip`, `ping`, and `nsenter` available, or use the Docker Desktop commands below.

```sh
sudo sh examples/bridge.sh
```

The script uses `nsenter -t <PID> -n` to configure the inner interfaces and run `ping` in each child's network namespace. Both children get addresses in `192.0.2.0/30`. The first ping times out while the veth pairs are separate. After both outer ends join the bridge, pings succeed in both directions.

### IPv4 forwarding and source NAT

Run this example on Linux with `ip`, `ping`, `nsenter`, and `iptables` available, or use the Docker Desktop commands below.

```sh
sudo sh examples/network-egress.sh
```

The script creates a router in its own network namespace. The client's bridge gateway is `192.0.2.1`. The router also has an interface at `198.51.100.1` connected to a separate upstream namespace at `198.51.100.2`. The experiment changes routes, IPv4 forwarding, and NAT only inside these namespaces.

The client first adds a default route through the bridge gateway. The router then enables IPv4 forwarding. The upstream reply succeeds with either an explicit route back to `192.0.2.0/30` or a source NAT rule that changes the client's source address to `198.51.100.1`. The final `iptables` output shows the packet count on the NAT rule.

### Applying image layers

An image layer records filesystem changes. `dckr image unpack` takes uncompressed local layer tar files in base-to-top order and assembles them in a new directory.

```sh
./dckr image unpack ./image-rootfs base.tar update.tar
```

This experiment supports regular files, directories, and OCI whiteouts. It preserves ordinary file permissions and creates directories with the default directory mode. `.wh.<name>` removes a lower entry, and `.wh..wh..opq` removes the lower contents of its directory. Each layer's whiteouts are applied before its regular entries, so files added in that layer survive regardless of archive order.

Run `sh examples/image-layers.sh` to generate two sample layers and check the merged files. If the assembled directory contains a runnable command and a `/proc` mount point, it can also be passed to `dckr run --rootfs`.

### Per-container writable layers

Use `--overlay-rootfs <directory>` to run on an OverlayFS root. The supplied rootfs is the shared `lowerdir`. For each run, `dckr` creates a temporary `upperdir` and `workdir` on the same private tmpfs and mounts the combined view as `/`. Writes go to the run's own upper layer and are discarded when the run ends. Keep the shared rootfs at a stable path outside the overlay workspace while the containers run.

With a prepared rootfs containing BusyBox at `/bin/busybox`, an `/etc/os-release` file, and a `/proc` mount point, run the comparison from the repository root.

```sh
sudo sh examples/overlay-rootfs.sh ./rootfs
```

Container A appends a line to `/etc/os-release` and creates a new file. Container B starts while A is still running and sees the original file. The script also checks the shared rootfs from outside both containers.

### Docker Desktop on macOS

Run the experiments from the repository root using a temporary ARM64 Go container in Docker Desktop's Linux VM. The container receives the source files and example scripts over standard input. `SYS_ADMIN` allows `dckr` to create namespaces, mount procfs, and switch the root mount. The cgroup experiments use a writable view of the temporary container's cgroup subtree. The launcher moves into its own child cgroup before enabling `cpu` and `memory` in its parent.

```sh
tar -cf - go.mod main.go image.go overlay.go examples/pid1-exit.sh examples/cgroup-cpu.sh examples/cgroup-memory.sh |
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

Run these examples in a temporary Go container with its own network namespace. The loopback experiment uses a comparison interface and route. The veth and bridge experiments create their own links. `NET_ADMIN` allows the examples to configure interfaces, and `NET_RAW` allows them to run `ping`.

```sh
tar -cf - go.mod main.go image.go overlay.go examples/network-namespace.sh examples/network-helpers.sh examples/veth.sh examples/bridge.sh |
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
      sh examples/bridge.sh
    '
```

#### IPv4 forwarding and NAT experiment

The temporary Go container uses Docker's bridge network to install `iptables` from Alpine's package repository. The experiment itself uses its own router and upstream namespaces and sends pings only between them.

```sh
tar -cf - go.mod main.go image.go overlay.go examples/network-helpers.sh examples/network-egress.sh |
  docker --context desktop-linux run --rm -i --platform linux/arm64 \
    --network bridge --cap-drop ALL --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add NET_RAW \
    docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
      apk add --no-cache iptables
      cd "$(mktemp -d)"
      tar -xf -
      go build -o dckr .
      sh examples/network-egress.sh
    '
```

#### Image layer experiment

```sh
tar -cf - go.mod main.go image.go overlay.go examples/image-layers.sh |
  docker --context desktop-linux run --rm -i --platform linux/arm64 \
    --network none --cap-drop ALL \
    docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
      cd "$(mktemp -d)"
      tar -xf -
      go build -o dckr .
      sh examples/image-layers.sh
    '
```

#### OverlayFS experiment

The temporary Go container builds a small rootfs from a tar layer. This example includes `SYS_ADMIN` and `DAC_OVERRIDE` for the OverlayFS mount in Docker Desktop.

```sh
tar -cf - go.mod main.go image.go overlay.go examples/overlay-rootfs.sh |
  docker --context desktop-linux run --rm -i --platform linux/arm64 \
    --network none --cap-drop ALL --cap-add SYS_ADMIN --cap-add DAC_OVERRIDE \
    docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
      cd "$(mktemp -d)"
      tar -xf -
      go build -o dckr .
      mkdir -p layer/bin layer/etc layer/lib layer/proc
      cp /bin/busybox layer/bin/
      cp -L /lib/ld-musl-aarch64.so.1 layer/lib/
      printf "NAME=\"shared base\"\n" > layer/etc/os-release
      tar -cf base.tar -C layer .
      ./dckr image unpack rootfs base.tar
      sh examples/overlay-rootfs.sh rootfs
    '
```

The project follows the workflow in [LEARNING_PROJECT.md](LEARNING_PROJECT.md).
