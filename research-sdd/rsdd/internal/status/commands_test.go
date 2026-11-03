package status

import "testing"

func TestShowIsRegistered(t *testing.T) {
	for _, c := range Commands {
		if c.Group == "status" && c.Name == "show" && c.Run != nil && c.Summary != "" {
			return
		}
	}
	t.Fatal("status show is not in the command table")
}
