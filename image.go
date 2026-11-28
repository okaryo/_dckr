//go:build linux

package main

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"
	"syscall"
)

const whiteoutPrefix = ".wh."
const opaqueWhiteout = ".wh..wh..opq"

func runImage(args []string) int {
	if len(args) < 3 || args[0] != "unpack" {
		fmt.Fprintln(os.Stderr, "usage: dckr image unpack <new-rootfs> <base.tar> [layer.tar...]")
		return 2
	}
	if err := unpackImage(args[1], args[2:]); err != nil {
		fmt.Fprintf(os.Stderr, "dckr: unpack image: %v\n", err)
		return 1
	}
	return 0
}

func unpackImage(destination string, layers []string) (err error) {
	if err := os.Mkdir(destination, 0o755); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			err = errors.Join(err, os.RemoveAll(destination))
		}
	}()

	root, err := os.OpenRoot(destination)
	if err != nil {
		return err
	}
	defer root.Close()
	for _, layer := range layers {
		if err := applyImageLayer(root, layer); err != nil {
			return fmt.Errorf("apply layer %q: %w", layer, err)
		}
	}
	return nil
}

func applyImageLayer(root *os.Root, filename string) error {
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer file.Close()

	// Whiteouts hide lower-layer files even when listed after new entries.
	if err := readImageLayer(root, file, true); err != nil {
		return err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	return readImageLayer(root, file, false)
}

func readImageLayer(root *os.Root, reader io.Reader, whiteoutsOnly bool) error {
	archive := tar.NewReader(reader)
	for {
		header, err := archive.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		name, err := layerPath(header.Name)
		if err != nil {
			return err
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeDir {
			return fmt.Errorf("unsupported entry type %q for %q", header.Typeflag, name)
		}
		if name == "." && header.Typeflag != tar.TypeDir {
			return fmt.Errorf("layer root must be a directory")
		}
		isWhiteout := strings.HasPrefix(path.Base(name), whiteoutPrefix)
		if whiteoutsOnly != isWhiteout {
			continue
		}
		if isWhiteout {
			if header.Typeflag != tar.TypeReg || header.Size != 0 {
				return fmt.Errorf("whiteout %q must be an empty regular file", name)
			}
			err = applyWhiteout(root, name)
		} else {
			err = applyLayerEntry(root, name, header, archive)
		}
		if err != nil {
			return fmt.Errorf("apply entry %q: %w", name, err)
		}
	}
}

func layerPath(raw string) (string, error) {
	if raw == "" || path.IsAbs(raw) {
		return "", fmt.Errorf("invalid layer path %q", raw)
	}
	for _, part := range strings.Split(raw, "/") {
		if part == ".." {
			return "", fmt.Errorf("invalid layer path %q", raw)
		}
	}
	name := path.Clean(raw)
	for _, part := range strings.Split(path.Dir(name), "/") {
		if strings.HasPrefix(part, whiteoutPrefix) {
			return "", fmt.Errorf("invalid whiteout directory in %q", raw)
		}
	}
	return name, nil
}

func applyWhiteout(root *os.Root, name string) error {
	parent := path.Dir(name)
	base := path.Base(name)
	target := strings.TrimPrefix(base, whiteoutPrefix)
	if target == "" || target == "." || target == ".." {
		return fmt.Errorf("invalid whiteout target %q", target)
	}
	info, err := root.Stat(parent)
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
		return nil
	}
	if err != nil || !info.IsDir() {
		return err
	}
	if base != opaqueWhiteout {
		return root.RemoveAll(path.Join(parent, target))
	}

	entries, err := fs.ReadDir(root.FS(), parent)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := root.RemoveAll(path.Join(parent, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func applyLayerEntry(root *os.Root, name string, header *tar.Header, contents io.Reader) error {
	if header.Typeflag == tar.TypeDir {
		return ensureLayerDir(root, name)
	}
	if err := ensureLayerDir(root, path.Dir(name)); err != nil {
		return err
	}
	if err := root.RemoveAll(name); err != nil {
		return err
	}
	file, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = io.Copy(file, contents); err == nil {
		err = file.Chmod(header.FileInfo().Mode().Perm())
	}
	return errors.Join(err, file.Close())
}

func ensureLayerDir(root *os.Root, name string) error {
	if name == "." {
		return nil
	}
	info, err := root.Stat(name)
	if err == nil {
		if info.IsDir() {
			return nil
		}
		if err := root.Remove(name); err != nil {
			return err
		}
	} else if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, syscall.ENOTDIR) {
		return err
	}
	if err := ensureLayerDir(root, path.Dir(name)); err != nil {
		return err
	}
	return root.Mkdir(name, 0o755)
}
