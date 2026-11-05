//go:build unix

package place

import (
	"os"
	"strconv"
	"testing"
)

func TestAliveKeepsEveryPidThatDoesNotNameOneProcess(t *testing.T) {
	for _, pid := range []string{"0", "-1", "", "x1", "2147483648", "4294967297", "99999999999999999999"} {
		if !Alive(pid) {
			t.Errorf("Alive(%q) = false: only a proven-dead pid may be swept", pid)
		}
	}
}

func TestAliveAnswersForARealPid(t *testing.T) {
	if !Alive(strconv.Itoa(os.Getpid())) {
		t.Error("this process is alive")
	}
	if !Alive("1") { // another user's process answers EPERM: still alive
		t.Error("pid 1 is alive")
	}
	if Alive("2147483646") {
		t.Error("an unused pid is dead")
	}
}
