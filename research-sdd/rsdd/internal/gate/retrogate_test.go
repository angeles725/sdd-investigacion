package gate

import "testing"

// TestRetroGate runs every scenario against the port alone and checks the scenario's own expectations (the
// differential test runs the same scenarios against the frozen bash too, and applies the same checks to it).
func TestRetroGate(t *testing.T) {
	for _, c := range rgCases {
		t.Run(c.id, func(t *testing.T) {
			rs := c.execute(t, false)
			c.check(t, rs)
		})
	}
}
