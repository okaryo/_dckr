# dckr

`dckr` is a small Go container runtime project for learning how Docker uses Linux kernel features. The experiments cover process visibility, filesystem isolation, CPU and memory limits, and container networking. The final stage builds a root filesystem from image layers and gives each container its own writable layer.

## Scope

The runtime starts with a foreground `run` command and grows one experiment at a time. Dockerfile builds, registry access, daemon-based management, and rootless execution are optional follow-ups.

## Getting started

Run the experiments on Linux with Go installed. From the repository root of a Linux VM, build `dckr` and run the PID namespace experiment with the privileges needed for `CLONE_NEWPID`.

```sh
go build -o dckr .
sudo ./dckr run -- /bin/sh -c 'echo "inside PID=$$"'
```

`outside PID` is the child's PID as seen by `dckr`. `inside PID` is `1` because the shell is the first process in the new namespace.

### Docker Desktop on macOS

Run the same experiment from the repository root using a temporary ARM64 Go container in Docker Desktop's Linux VM. The container receives the two source files over standard input. `SYS_ADMIN` allows `dckr` to create the new PID namespace.

```sh
tar -cf - go.mod main.go |
  docker --context desktop-linux run --rm -i --platform linux/arm64 \
    --network none --cap-drop ALL --cap-add SYS_ADMIN \
    docker.io/library/golang:1.27.4-alpine3.24 sh -ec '
      cd "$(mktemp -d)"
      tar -xf -
      go build -o dckr .
      ./dckr run -- /bin/sh -c "echo inside PID=\$\$"
    '
```

Here, the outer PID namespace is the temporary Go container's namespace. See [TODO.md](TODO.md) for recorded results and the full roadmap.

The project follows the workflow in [LEARNING_PROJECT.md](LEARNING_PROJECT.md).
