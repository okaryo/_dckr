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
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) > 0 && args[0] == "init" {
		if err := initContainer(args[1:]); err != nil {
			fmt.Fprintf(os.Stderr, "dckr: %v\n", err)
		}
		return 1
	}
	if len(args) < 3 || args[0] != "run" || args[1] != "--" {
		fmt.Fprintln(os.Stderr, "usage: dckr run -- <command> [args...]")
		return 2
	}

	parentMountNamespace, err := os.Readlink(mountNamespacePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dckr: read parent mount namespace: %v\n", err)
		return 1
	}

	initArgs := append([]string{"init", parentMountNamespace}, args[2:]...)
	cmd := exec.Command("/proc/self/exe", initArgs...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Cloneflags: syscall.CLONE_NEWPID | syscall.CLONE_NEWNS}
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

func initContainer(args []string) error {
	if len(args) < 2 || os.Getpid() != 1 {
		return errors.New("init requires a command and must run as PID 1")
	}
	childMountNamespace, err := os.Readlink(mountNamespacePath)
	if err != nil {
		return fmt.Errorf("read child mount namespace: %w", err)
	}
	if childMountNamespace == args[0] {
		return errors.New("init must run in a new mount namespace")
	}

	commandArgs := args[1:]
	path, err := exec.LookPath(commandArgs[0])
	if err != nil {
		return err
	}

	if err := syscall.Mount("", "/", "", syscall.MS_REC|syscall.MS_PRIVATE, ""); err != nil {
		return fmt.Errorf("make mounts private: %w", err)
	}
	if err := syscall.Mount("proc", "/proc", "proc", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, ""); err != nil {
		return fmt.Errorf("mount procfs: %w", err)
	}

	// Exec replaces this process with the command, preserving its PID.
	return syscall.Exec(path, commandArgs, os.Environ())
}
