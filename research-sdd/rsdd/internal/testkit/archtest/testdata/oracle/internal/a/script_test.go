package a

import "os/exec"

func run4() { _ = exec.Command("/usr/bin/env", "../../toolbelt/analysis_manifest.py") }
