# Docker Learning Roadmap

## Learning Goal

Build a small container runtime in Go to understand how Docker isolates processes, filesystems, and networks, and how it controls CPU and memory usage. Then explore how image layers form a container's root filesystem.

Run the experiments in an ARM64 Linux VM. For the PID experiment, the outer namespace is the namespace where `dckr` runs. Start with a foreground `dckr run` command.

## First Milestone

Compare the PID of the same child process from the outer namespace and from inside its new PID namespace. The experiment and the understanding check are complete.

- [x] Verify that Go can build and run a program in the Linux VM.
- [x] Use `os/exec` to implement `dckr run -- <command> [args...]`. Connect the child's standard output to the terminal, print its PID from the parent, and wait for the child to exit.
- [x] Run `./dckr run -- /bin/sh -c 'echo "inside PID=$$"'` and confirm that the PID printed by the parent matches the shell's `$$`.
- [x] Set `CLONE_NEWPID` in `syscall.SysProcAttr.Cloneflags` and run the same command. Confirm that the shell prints PID `1` and the parent prints the child's PID in the outer namespace.
- [x] Explain why the child has PID `1` as the first process in its new namespace, even when its PID in the outer namespace changes between runs.

### Linux Build Check

Docker Desktop's Linux VM ran this check in a temporary ARM64 container using the official Go image.

```sh
docker --context desktop-linux run --rm -i --platform linux/arm64 --network none docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
  go version
  uname -sm
  test "$(go env GOOS GOARCH)" = "$(printf "linux\narm64")"
  cd "$(mktemp -d)"
  cat > main.go
  go build -o check main.go
  ./check
' <<'GO'
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Printf("Go program ran on %s/%s\n", runtime.GOOS, runtime.GOARCH)
}
GO
```

The program printed `Go program ran on linux/arm64` and exited successfully.

### Baseline PID Comparison

Before setting `CLONE_NEWPID`, the experiment on ARM64 Linux printed `outside PID=1190` from `dckr` and `inside PID=1190` from the shell. The two numbers matched because both processes shared a PID namespace.

### PID Namespace Comparison

With `CLONE_NEWPID`, the [Docker Desktop experiment](README.md#docker-desktop-on-macos) printed `outside PID=1217` and `inside PID=1`. Both numbers identify the same shell. The outer PID varies between runs, and the first process in each new PID namespace always starts at `1`.

## Mount Namespace and procfs

- [x] Start a child in new PID and mount namespaces. Give it a fresh procfs at `/proc`, then execute the requested command in the same process.
- [x] Compare `ps` output from the PID-only build and the build that mounts procfs. Confirm that the outer `/proc` mount stays the same.
- [x] Explain how the child's new procfs limits its `ps` output while the outer `ps` can still list the outer `sleep` process.

In the ARM64 Linux experiment, `ps` in the PID-only build (`49460ce`) listed the outer `sleep` process and the parent `dckr`. With a fresh procfs, it listed only the shell at PID `1` and `ps` itself. The `sleep` process remained visible to `ps` outside, and the outer `/proc` mount kept its mount ID. The current experiment is reproducible from the [README](README.md#getting-started).

## PID 1 Exit

- [x] Start a worker inside the namespace and let PID `1` exit while the worker is running.
- [x] Confirm from the outer namespace that the inner worker disappears and that an outer worker keeps running.
- [x] Explain why the inner worker's lifetime depends on PID `1` and how the namespace boundary determines which processes are terminated.

On ARM64 Linux, the inner `sleep` had PID `6` inside and PID `781` outside. The outer `/proc/781` entry disappeared when the inner shell exited, while a separate outer `sleep` kept running. See the [example](examples/pid1-exit.sh) and [run instructions](README.md#pid-1-exit).

## Root Filesystem

- [x] Add `--rootfs` to bind-mount an unpacked directory, make it `/` with `pivot_root`, and detach the old root inside the child's mount namespace.
- [x] Compare `/etc/os-release` inside and outside. Check that a file present only outside is absent inside and that the child can still read `/proc/1/status`.
- [x] Explain why opening the same absolute path from the two sides can return different files.

On ARM64 Linux, `/etc/os-release` reported `NAME="Alpine Linux"` outside and `NAME="dckr rootfs"` inside. The [Docker Desktop commands](README.md#docker-desktop-on-macos) prepare the minimal rootfs and reproduce the comparison.

## cgroup v2 CPU Limits

- [x] Start the `dckr` child directly in a prepared cgroup v2 leaf with `--cgroup`.
- [x] Run the same CPU-heavy workload with `cpu.max` set to `max 100000` and `25000 100000`. Compare CPU usage and throttling in `cpu.stat`.
- [x] Explain what the two values in `cpu.max` mean and what happens when the group spends its quota before the period ends.

On ARM64 Linux, the two-second workload used `2008687` microseconds of CPU time with no local quota and `513260` microseconds with the quota. `nr_throttled` was `0` in the baseline and `20` in the limited group. See the [run instructions](README.md#cpu-limits-with-cgroup-v2).

## cgroup v2 Memory Limits

- [x] Run the same 64 MiB memory workload in a baseline cgroup and a cgroup with `memory.max` set to 32 MiB.
- [x] Compare the exit status and `memory.events` for both runs.
- [x] Explain how `memory.events` shows that the worker was killed because of an out-of-memory condition.

On ARM64 Linux, the baseline worker touched all 64 MiB, exited with status `0`, and recorded `oom_kill 0`. In the limited group, the kernel killed the worker, `dckr` returned status `1`, and `memory.events` recorded `oom 1` and `oom_kill 1`. See the [run instructions](README.md#memory-limits-with-cgroup-v2).

## Network Namespace and Loopback

- [x] Add `--network none` and compare the interfaces and IPv4 routes with the default run.
- [x] Bring up `lo` inside the new namespace and verify that `127.0.0.1` responds there.
- [x] Explain which network namespace a loopback packet stays in and why bringing up `lo` alone leaves the outer interface unreachable.

On ARM64 Linux, the default run saw `dckr-outer` and its route for `192.0.2.0/24`. The new namespace showed neither and had its own `lo`, initially down. After `ip link set dev lo up`, a ping to `127.0.0.1` received a reply. The LinuxKit kernel also created unconfigured tunnel devices in the new namespace. See the [run instructions](README.md#network-namespace-experiment).

## Connecting Network Namespaces with veth

- [x] Create a veth pair and move one endpoint to the `dckr` child's network namespace.
- [x] Assign both endpoints addresses in `192.0.2.0/30` and confirm that ping works in both directions.
- [x] Explain how a packet sent on one veth endpoint reaches the other network namespace.

On ARM64 Linux, the outer `192.0.2.1` and inner `192.0.2.2` each received one response to one ping. The temporary pair and route disappeared after the child exited. See the [example](examples/veth.sh) and [run instructions](README.md#connecting-namespaces-with-veth).

## Linux Bridge

- [x] Start two `dckr` children in separate network namespaces and give them addresses in the same subnet on two separate veth pairs.
- [x] Compare ping before and after connecting both outer veth endpoints to the same Linux bridge.
- [x] Explain how the bridge connects the two veth pairs and why the children can reach each other.

On ARM64 Linux, the first ping from `192.0.2.1` to `192.0.2.2` received no reply. After both outer veth endpoints joined the bridge, each child received a reply from the other. The bridge and the veth links were removed after the experiment. See the [example](examples/bridge.sh) and [run instructions](README.md#connecting-two-namespaces-with-a-bridge).

## IPv4 Forwarding and Source NAT

- [x] Connect a client on a bridge to a separate upstream subnet through an isolated router namespace.
- [x] Compare ping before and after adding the default route, enabling forwarding, and providing a return path.
- [x] Remove the upstream return route and confirm that source NAT makes ping work again.
- [x] Explain what address the upstream replies to after source NAT and how the router returns the reply to the client.

On ARM64 Linux, the client reached its gateway at `192.0.2.1`, but its ping to `198.51.100.2` received no reply until the router forwarded packets and the upstream had a return path. An explicit return route worked. After removing it, source NAT to `198.51.100.1` also worked, and the NAT rule counted one packet. The enclosing network namespace kept its original links, routes, and forwarding setting. See the [example](examples/network-egress.sh) and [run instructions](README.md#ipv4-forwarding-and-nat-experiment).

## Roadmap

### 1. Namespaces

- **Question** — Which processes can a process inside a container see?
- **Experiment** — After the first milestone, create a mount namespace and remount `/proc` from inside the new PID namespace. Then run an experiment that lets PID 1 exit while another process is still running.
- **Observation** — Compare `ps` output before and after remounting `/proc`. When PID 1 exits, the remaining processes in its PID namespace also terminate.

### 2. Filesystem

- **Question** — How can the host and a container see different files at the same absolute path?
- **Experiment** — Prepare an unpacked minimal root filesystem. Set mount propagation to private, switch `/` with `pivot_root`, and unmount the old root.
- **Observation** — Give the two root filesystems distinct `/etc/os-release` contents. Read that path from the host side and from inside the container to see which root each process uses.

### 3. cgroups

- **Question** — How can Linux limit the CPU time and memory available to a container's processes?
- **Experiment** — Set `cpu.max` and `memory.max` in cgroup v2 and place the child in the cgroup before it runs the workload. Compare the same workload with and without the limits.
- **Observation** — Check `cpu.stat` for throttling. For a workload that keeps allocating memory, use `memory.events` and the process's exit status to see what happens at the memory limit.

### 4. Networking

- **Question** — How can containers with separate network namespaces reach one another and external destinations?
- **Experiment** — Connect a child namespace to the outer namespace with one veth pair. Then connect two child namespaces to a Linux bridge with separate veth pairs. Set the bridge IP as the containers' default gateway, then enable IP forwarding and NAT on the VM side.
- **Observation** — At each step, test connectivity by IP address to the other container and to an upstream destination on a separate subnet.

### 5. Images

- **Question** — How do image layers form a root filesystem, and where do container writes go?
- **Experiment** — Apply local OCI layers in order, including a file replacement and a deletion. Use the resulting root filesystem as a read-only OverlayFS lower layer and give each container its own writable upper layer.
- **Observation** — Verify the file replacement and deletion in the assembled root filesystem. Start two containers from it and verify that a write in one is visible only in that container.

## Optional Follow-ups

- Dockerfile builds
- Pulling images from a registry
- Daemon-based container management
- Rootless execution and user namespaces
