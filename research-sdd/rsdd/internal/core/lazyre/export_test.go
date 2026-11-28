package lazyre

import "testing"

// unregisterForTest drops r from the registry so a deliberately bad pattern does not leak into CompileAll.
func unregisterForTest(t *testing.T, r *Regexp) {
	t.Helper()
	mu.Lock()
	defer mu.Unlock()
	for i, x := range registry {
		if x == r {
			registry = append(registry[:i:i], registry[i+1:]...)
			return
		}
	}
}

// swapRegistryForTest replaces the registry and returns the previous one.
func swapRegistryForTest(in []*Regexp) []*Regexp {
	mu.Lock()
	defer mu.Unlock()
	prev := registry
	registry = in
	return prev
}
