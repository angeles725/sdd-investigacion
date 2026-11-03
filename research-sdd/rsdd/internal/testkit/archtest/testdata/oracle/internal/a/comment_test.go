package a

import "os/exec"

// The oracle used to be python3 running testdata/legacy/old.py; it is gone.
func run5() { _ = exec.Command("bash", "-c", "true") }
