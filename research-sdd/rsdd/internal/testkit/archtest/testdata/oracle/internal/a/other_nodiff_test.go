//go:build !nodiff || windows

package a

import "os/exec"

func run7() { _ = exec.Command("python3") }
