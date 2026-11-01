package skilldrift

import (
	"path/filepath"
)

// selfDirKey names the variable through which the shims hand over their own physical directory (the RSDD-SELF-DIR idiom's
// result): a binary cannot see the shim's location, and the scripts resolved everything relative to it.
const selfDirKey = "RSDD_TOOLBELT_DIR"

// kitPaths are the directories the scripts derived from SELF_DIR, all physical (`cd -P ... && pwd -P`): a toolbelt/ reached
// through a symlink, as the persisted render dir's is, must still land on the real kit root (kit issue #1024 round 4).
type kitPaths struct {
	selfDir    string // the toolbelt directory
	kitInstall string // <self>/../install, symlinks resolved
	kit        string // <install>/.., symlinks resolved: the kit root
}

// physicalDir is `cd -P dir && pwd -P`.
func physicalDir(dir string) (string, bool) {
	p, err := filepath.EvalSymlinks(dir)
	if err != nil || !isDir(p) {
		return "", false
	}
	abs, err := filepath.Abs(p)
	return abs, err == nil
}

// resolveInstall is the first step of the scripts: SELF_DIR and KIT_INSTALL. ok is false when the install directory is not
// there. The kit root is resolved later (kitRoot), after the arguments, as the script does.
func resolveInstall(selfDir string) (kitPaths, bool) {
	k := kitPaths{selfDir: selfDir}
	if selfDir == "" {
		return k, false
	}
	if phys, ok := physicalDir(selfDir); ok {
		k.selfDir = phys // the shim already hands over a physical path; a caller that does not gets the same answer
	}
	p, ok := physicalDir(filepath.Join(k.selfDir, "..", "install"))
	k.kitInstall = p
	return k, ok
}

// kitRoot is `KIT="$(cd -P "$KIT_INSTALL/.." && pwd -P)"`.
func (k *kitPaths) kitRoot() {
	k.kit, _ = physicalDir(filepath.Join(k.kitInstall, ".."))
}
