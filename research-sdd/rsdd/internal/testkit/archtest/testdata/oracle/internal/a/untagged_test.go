//go:build linux

package a

import "os/exec"

func run2() { _ = exec.Command("python3.12", "x") }
