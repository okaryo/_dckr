package main

import (
	"fmt"
	"os"
	"os/exec"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) < 3 || args[0] != "run" || args[1] != "--" {
		fmt.Fprintln(os.Stderr, "usage: dckr run -- <command> [args...]")
		return 2
	}

	cmd := exec.Command(args[2], args[3:]...)
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
