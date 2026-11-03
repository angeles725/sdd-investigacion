//go:build !windows

package a

import (
	"context"
	"os/exec"
)

func run3() { _ = exec.CommandContext(context.Background(), "bash", "testdata/legacy/tool.sh") }
