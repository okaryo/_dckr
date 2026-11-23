# dckr

`dckr` is a small Go container runtime project for learning how Docker uses Linux kernel features. The experiments cover process visibility, filesystem isolation, CPU and memory limits, and container networking. The final stage builds a root filesystem from image layers and gives each container its own writable layer.

## Scope

The runtime starts with a foreground `run` command and grows one experiment at a time. Dockerfile builds, registry access, daemon-based management, and rootless execution are optional follow-ups.

## Getting started

Run the experiments inside an ARM64 Linux VM with Go installed. In this project, the host side means the environment inside the VM and outside the container.

The project is at the documentation setup stage. The first milestone will add `dckr run -- <command> [args...]` and use it to compare the same process's PID inside and outside a PID namespace. See [TODO.md](TODO.md) for the first experiment and the full roadmap.

The project follows the workflow in [LEARNING_PROJECT.md](LEARNING_PROJECT.md).
