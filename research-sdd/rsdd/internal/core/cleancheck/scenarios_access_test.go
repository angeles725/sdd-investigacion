package cleancheck

import "os"

// chmodBack changes a mode for the case and restores 0755 when it ends (the temp directory must stay removable).
func chmodBack(w *world, path string, mode os.FileMode) {
	if err := os.Chmod(path, mode); err != nil {
		w.t.Fatal(err)
	}
	w.t.Cleanup(func() { _ = os.Chmod(path, 0o755) })
}

// accessScenarios are the directories whose mode the script's `cd -P` and the engine's EvalSymlinks judge differently.
func accessScenarios() []scenario {
	return []scenario{
		{name: "scratchpad-without-search-permission", root: true, diverges: "script: cd fails inside the assignment, scratchpad silently not set, exit 0", legacyRC: 0, build: func(w *world) {
			keep(w, "")
			w.writeAt(w.scratch+"/a.sh", "x")
			chmodBack(w, w.scratch, 0o666)
		}, args: withScratch(), want: 2},
		{name: "empty-tmp-dir-readable-but-not-searchable", root: true, diverges: "same refusal; the shell's own cd: diagnostic line is not reproduced", legacyRC: 2, build: func(w *world) {
			keep(w, "")
			chmodBack(w, w.tmp, 0o444)
		}, args: std(), want: 2},
	}
}
