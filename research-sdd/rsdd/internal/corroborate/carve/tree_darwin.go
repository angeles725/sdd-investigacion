package carve

// processTree has no /proc to read here: the process cap cannot be observed, so it counts nothing. The carve
// itself needs bubblewrap and never runs on this platform.
func processTree(int) int { return 0 }
