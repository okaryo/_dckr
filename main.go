//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

const mountNamespacePath = "/proc/self/ns/mnt"

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "image" {
		os.Exit(runImage(args[1:]))
	}
	os.Exit(run(args))
}

func run(args []string) int {
	if len(args) > 0 && args[0] == "init" {
		if err := initContainer(args[1:]); err != nil {
			fmt.Fprintf(os.Stderr, "dckr: %v\n", err)
		}
		return 1
	}
	if len(args) == 0 || args[0] != "run" {
		return runUsage()
	}
	args = args[1:]

	rootfs := ""
	overlayRootfs := ""
	cgroupPath := ""
	isolateNetwork := false
	for len(args) >= 2 && args[0] != "--" {
		if args[1] == "" {
			return runUsage()
		}
		switch args[0] {
		case "--rootfs":
			rootfs = args[1]
		case "--overlay-rootfs":
			overlayRootfs = args[1]
		case "--cgroup":
			cgroupPath = args[1]
		case "--network":
			if args[1] != "none" {
				return runUsage()
			}
			isolateNetwork = true
		default:
			return runUsage()
		}
		args = args[2:]
	}
	if len(args) < 2 || args[0] != "--" || (rootfs != "" && overlayRootfs != "") {
		return runUsage()
	}

	parentMountNamespace, err := os.Readlink(mountNamespacePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dckr: read parent mount namespace: %v\n", err)
		return 1
	}

	overlayWorkspace := ""
	if overlayRootfs != "" {
		overlayWorkspace, err = newOverlayWorkspace(overlayRootfs)
		if err != nil {
			fmt.Fprintf(os.Stderr, "dckr: prepare overlay rootfs: %v\n", err)
			return 1
		}
		defer func() {
			if err := os.Remove(overlayWorkspace); err != nil {
				fmt.Fprintf(os.Stderr, "dckr: remove overlay workspace: %v\n", err)
			}
		}()
		rootfs = overlayRootfs
	}

	initArgs := append([]string{"init", parentMountNamespace, rootfs, overlayWorkspace}, args[1:]...)
	cmd := exec.Command("/proc/self/exe", initArgs...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Cloneflags: syscall.CLONE_NEWPID | syscall.CLONE_NEWNS}
	if isolateNetwork {
		cmd.SysProcAttr.Cloneflags |= syscall.CLONE_NEWNET
	}
	if cgroupPath != "" {
		cgroupFD, err := syscall.Open(cgroupPath, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC, 0)
		if err != nil {
			fmt.Fprintf(os.Stderr, "dckr: open cgroup %q: %v\n", cgroupPath, err)
			return 1
		}
		defer syscall.Close(cgroupFD)
		cmd.SysProcAttr.UseCgroupFD = true
		cmd.SysProcAttr.CgroupFD = cgroupFD
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "dckr: %v\n", err)
		return 1
	}
	fmt.Printf("outside PID=%d\n", cmd.Process.Pid)
	if err := cmd.Wait(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok && exitError.ExitCode() >= 0 {
			return exitError.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "dckr: %v\n", err)
		return 1
	}
	return 0
}

func runUsage() int {
	fmt.Fprintln(os.Stderr, "usage: dckr run [--rootfs <directory> | --overlay-rootfs <directory>] [--cgroup <directory>] [--network none] -- <command> [args...]")
	return 2
}

func initContainer(args []string) error {
	if len(args) < 4 || os.Getpid() != 1 {
		return errors.New("init requires a command and must run as PID 1")
	}
	childMountNamespace, err := os.Readlink(mountNamespacePath)
	if err != nil {
		return fmt.Errorf("read child mount namespace: %w", err)
	}
	if childMountNamespace == args[0] {
		return errors.New("init must run in a new mount namespace")
	}

	if err := syscall.Mount("", "/", "", syscall.MS_REC|syscall.MS_PRIVATE, ""); err != nil {
		return fmt.Errorf("make mounts private: %w", err)
	}
	rootfs := args[1]
	if workspace := args[2]; workspace != "" {
		rootfs, err = mountOverlayRoot(rootfs, workspace)
		if err != nil {
			return err
		}
	}
	if rootfs != "" {
		if err := switchRoot(rootfs); err != nil {
			return err
		}
	}
	if err := syscall.Mount("proc", "/proc", "proc", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, ""); err != nil {
		return fmt.Errorf("mount procfs: %w", err)
	}

	commandArgs := args[3:]
	path, err := exec.LookPath(commandArgs[0])
	if err != nil {
		return err
	}

	// Exec replaces this process with the command, preserving its PID.
	return syscall.Exec(path, commandArgs, os.Environ())
}

func switchRoot(rootfs string) error {
	if err := syscall.Mount(rootfs, rootfs, "", syscall.MS_BIND, ""); err != nil {
		return fmt.Errorf("bind mount rootfs %q: %w", rootfs, err)
	}
	if err := os.Chdir(rootfs); err != nil {
		return fmt.Errorf("enter rootfs %q: %w", rootfs, err)
	}
	// Stack the old root on the new root so it can be detached at ".".
	if err := syscall.PivotRoot(".", "."); err != nil {
		return fmt.Errorf("pivot root to %q: %w", rootfs, err)
	}
	if err := syscall.Unmount(".", syscall.MNT_DETACH); err != nil {
		return fmt.Errorf("detach old root: %w", err)
	}
	if err := os.Chdir("/"); err != nil {
		return fmt.Errorf("enter new root: %w", err)
	}
	return nil
}
