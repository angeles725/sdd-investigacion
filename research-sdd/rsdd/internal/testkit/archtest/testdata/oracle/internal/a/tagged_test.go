//go:build linux && !nodiff

package a

import "os/exec"

func run() { _ = exec.Command("python3", "-I", "testdata/driver.py") }
