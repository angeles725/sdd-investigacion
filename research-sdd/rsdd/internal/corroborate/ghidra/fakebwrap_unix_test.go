//go:build unix

package ghidra

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
)

// The test binary doubles as a fake Bubblewrap: the staged launcher is a copy of it, executed through
// /proc/self/fd with argv[0] "tool/bwrap". The fake keeps the real sandbox's argument grammar but, instead of
// namespaces, maps guest paths (/tmp/rsdd/...) to the host paths named by --bind/--ro-bind and execs the command,
// so the real process runner, descriptor passing and group reaping are exercised with no kernel support.

var sharedBwrap string // a copy of the test binary every world links as bin/bwrap

func TestMain(m *testing.M) {
	if len(os.Args) > 0 && os.Args[0] == logicalBwrap {
		os.Exit(fakeBwrapMain(os.Args[1:]))
	}
	dir, err := os.MkdirTemp("", "ghidra-fake-bwrap")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	self, err := os.Executable()
	if err == nil {
		sharedBwrap = filepath.Join(dir, "bwrap")
		err = copyFile(self, sharedBwrap, 0o755)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}

type bind struct{ host, guest string }

func fakeBwrapMain(args []string) int {
	cwd, _ := os.Getwd()
	var binds []bind
	env := os.Environ()
	chdir := ""
	i := 0
	for ; i < len(args) && args[i] != "--"; i++ {
		switch args[i] {
		case "--ro-bind", "--bind":
			host := args[i+1]
			if !filepath.IsAbs(host) {
				host = filepath.Join(cwd, host)
			}
			binds = append(binds, bind{host, args[i+2]})
			i += 2
		case "--setenv":
			env = append(env, args[i+1]+"="+args[i+2])
			i += 2
		case "--chdir":
			chdir = args[i+1]
			i++
		case "--proc", "--dev", "--tmpfs", "--dir":
			i++
		}
	}
	sort.SliceStable(binds, func(a, b int) bool { return len(binds[a].guest) > len(binds[b].guest) })
	mapPath := func(x string) string {
		for _, b := range binds {
			if x == b.guest || strings.HasPrefix(x, b.guest+"/") {
				return b.host + x[len(b.guest):]
			}
		}
		return x
	}
	inner := args[i+1:]
	if len(inner) == 0 {
		return 125
	}
	mapped := make([]string, len(inner))
	for k, a := range inner {
		mapped[k] = mapPath(a)
	}
	if chdir != "" {
		if err := os.Chdir(mapPath(chdir)); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 126
		}
	}
	// A real sandbox resolves the command through its synthetic PATH; the fake only needs absolute commands.
	err := syscall.Exec(mapped[0], mapped, env)
	fmt.Fprintln(os.Stderr, "fake bwrap exec:", err)
	return 127
}

// linkBwrap puts the shared fake launcher at dst (a hard link when the file system allows, else a copy).
func linkBwrap(t *testing.T, dst string) {
	t.Helper()
	if err := os.Link(sharedBwrap, dst); err != nil {
		must(t, copyFile(sharedBwrap, dst, 0o755))
	}
}
