package runner

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"testing"
	"time"
)

func look(name string) (string, error) { return exec.LookPath(name) }

func sh(t *testing.T, env []string, script string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	rc := Exec{Env: env, Look: look}.Run(context.Background(), []string{"sh", "-c", script}, &out, &errb)
	return rc, out.String(), errb.String()
}

func TestRunPassesTheExitStatusAndBothStreams(t *testing.T) {
	rc, out, errs := sh(t, []string{"X=1"}, `echo "out:$X"; echo err >&2; exit 3`)
	if rc != 3 || out != "out:1\n" || errs != "err\n" {
		t.Errorf("rc=%d out=%q err=%q", rc, out, errs)
	}
	if rc, _, _ := sh(t, nil, `exit 0`); rc != 0 {
		t.Errorf("success is %d", rc)
	}
}

func TestRunReportsASignalAs128PlusN(t *testing.T) {
	if rc, _, _ := sh(t, nil, `kill -9 $$`); rc != 137 {
		t.Errorf("rc=%d, want 137", rc)
	}
}

func TestRunNotFoundAndEmptyArgv(t *testing.T) {
	e := Exec{Look: look}
	if rc := e.Run(context.Background(), []string{"no-such-program-xyz"}, nil, nil); rc != NotFound {
		t.Errorf("missing program: %d", rc)
	}
	if rc := e.Run(context.Background(), nil, nil, nil); rc != NotFound {
		t.Errorf("empty argv: %d", rc)
	}
	bad := Exec{Look: func(string) (string, error) { return "/nonexistent/prog", nil }}
	if rc := bad.Run(context.Background(), []string{"x"}, nil, nil); rc != NotFound {
		t.Errorf("unstartable program: %d", rc)
	}
	failing := Exec{Look: func(string) (string, error) { return "", errors.New("no") }}
	if rc := failing.Run(context.Background(), []string{"x"}, nil, nil); rc != NotFound {
		t.Errorf("lookup failure: %d", rc)
	}
}

func TestRunCancelTerminatesTheProcessGroup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)
	go func() {
		done <- Exec{Look: look}.Run(ctx, []string{"sh", "-c", "sleep 30 & wait"}, nil, nil)
	}()
	time.Sleep(200 * time.Millisecond)
	cancel()
	select {
	case rc := <-done:
		if rc != 143 {
			t.Errorf("rc=%d, want 143", rc)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the run did not stop after the cancel")
	}
}
