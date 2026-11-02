package firmware

// processTree has no /proc to read here: the process cap cannot be observed, so it counts nothing. The
// analyzer needs bubblewrap and never runs on this platform.
func processTree(int) int { return 0 }
