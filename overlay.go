//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func newOverlayWorkspace(lower string) (string, error) {
	const workspaceParent = "/tmp"
	lowerPath, err := filepath.Abs(lower)
	if err != nil {
		return "", err
	}
	lowerPath, err = filepath.EvalSymlinks(lowerPath)
	if err != nil {
		return "", err
	}
	tempPath, err := filepath.EvalSymlinks(workspaceParent)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(lowerPath, tempPath)
	if err != nil {
		return "", err
	}
	if filepath.IsLocal(relative) {
		return "", fmt.Errorf("overlay lower directory %q contains %s", lower, workspaceParent)
	}
	return os.MkdirTemp(workspaceParent, "dckr-overlay-")
}

func mountOverlayRoot(lower, workspace string) (string, error) {
	// Both the upper and work directories must be on the same filesystem.
	if err := syscall.Mount("tmpfs", workspace, "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=0700"); err != nil {
		return "", fmt.Errorf("mount overlay workspace: %w", err)
	}
	lowerDir := filepath.Join(workspace, "lower")
	upperDir := filepath.Join(workspace, "upper")
	workDir := filepath.Join(workspace, "work")
	mergedDir := filepath.Join(workspace, "merged")
	for _, dir := range []string{lowerDir, upperDir, workDir, mergedDir} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			return "", err
		}
	}
	// Use a private bind mount so the caller's path is not part of the mount options.
	if err := syscall.Mount(lower, lowerDir, "", syscall.MS_BIND, ""); err != nil {
		return "", fmt.Errorf("bind mount overlay lower %q: %w", lower, err)
	}
	options := fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lowerDir, upperDir, workDir)
	if err := syscall.Mount("overlay", mergedDir, "overlay", syscall.MS_NOSUID|syscall.MS_NODEV, options); err != nil {
		return "", fmt.Errorf("mount overlay rootfs: %w", err)
	}
	return mergedDir, nil
}
