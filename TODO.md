# Docker Learning Roadmap

## Learning Goal

Build a small container runtime in Go to understand how Docker isolates processes, filesystems, and networks, and how it controls CPU and memory usage. Then explore how image layers form a container's root filesystem.

Run the experiments in an ARM64 Linux VM. The host side means the environment inside the VM and outside the container. Start with a foreground `dckr run` command.

## First Milestone

Compare the PID of the same child process from the host side and from inside a PID namespace. This milestone is pending.

- [ ] Verify that Go can build and run a program in the Linux VM.
- [ ] Use `os/exec` to implement `dckr run -- <command> [args...]`. Connect the child's standard output to the terminal, print its PID from the parent, and wait for the child to exit.
- [ ] Run `dckr run -- /bin/sh -c 'echo "inside PID=$$"'` and confirm that the PID printed by the parent matches the shell's `$$`.
- [ ] Set `CLONE_NEWPID` in `syscall.SysProcAttr.Cloneflags` and run the same command. Confirm that the shell prints PID `1` and the parent prints the child's PID in the host namespace.
- [ ] Explain in your own words why the same process has two PIDs. The milestone is complete when the comparison is reproducible and you can explain the result.

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
- **Experiment** — Connect two network namespaces to a Linux bridge with veth pairs. Set the bridge IP as the containers' default gateway, then enable IP forwarding and NAT on the VM side.
- **Observation** — At each step, test connectivity by IP address to the other container and to a destination outside the VM.

### 5. Images

- **Question** — How do image layers form a root filesystem, and where do container writes go?
- **Experiment** — Apply local OCI layers in order, including a file replacement and a deletion. Use the resulting root filesystem as a read-only OverlayFS lower layer and give each container its own writable upper layer.
- **Observation** — Verify the file replacement and deletion in the assembled root filesystem. Start two containers from it and verify that a write in one is visible only in that container.

## Optional Follow-ups

- Dockerfile builds
- Pulling images from a registry
- Daemon-based container management
- Rootless execution and user namespaces
