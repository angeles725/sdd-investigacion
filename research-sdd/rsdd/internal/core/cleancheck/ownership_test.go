package cleancheck

import "testing"

// noOwners makes the platform unable to tell who owns a file, for the case.
func noOwners(t *testing.T) {
	t.Helper()
	old := ownershipKnown
	t.Cleanup(func() { ownershipKnown = old })
	ownershipKnown = false
}

const ownershipLine = "DEGRADED-STALE-TMP-OWNERSHIP the owner of tmp.* entries cannot be determined on this platform; stale-tmp not evaluated"

// Where files carry no owner the stale-tmp check cannot look; it says so (typed, exit 3) instead of reporting an empty
// list that reads as "nothing stale".
func TestUnknownOwnershipDegradesTheStaleTmpCheck(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	ageTmp(w, "tmp.old", 48, false)
	noOwners(t)
	r := w.check()
	if r.Exit != 3 || r.Verdict != Degraded || len(r.Degraded) != 1 || r.Degraded[0] != DegradedOwnership || !has(r, ownershipLine) {
		t.Fatal(w.dump(r))
	}
	if hasPrefix(r, "GARBAGE stale-tmp") || !hasPrefix(r, "CLEAN-CHECK: degraded (") {
		t.Error("nothing may be claimed about the tmp entries:\n" + w.dump(r))
	}
}

// A real finding still wins over the degraded check (exit 1), and the degraded kind is still reported.
func TestUnknownOwnershipDoesNotHideAFinding(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.write("stray.txt", "x")
	noOwners(t)
	r := w.check()
	if r.Exit != 1 || len(r.Degraded) != 1 || r.Degraded[0] != DegradedOwnership || !has(r, "GARBAGE untracked stray.txt") {
		t.Fatal(w.dump(r))
	}
}

// Where owners are known nothing is degraded: the guard is not a blanket skip.
func TestKnownOwnershipIsNotDegraded(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	ageTmp(w, "tmp.old", 48, false)
	if !ownershipKnown {
		t.Skip("this platform reports no file owners")
	}
	r := w.check()
	if len(r.Degraded) != 0 || !has(r, "GARBAGE stale-tmp "+w.tmp+"/tmp.old age=48h") {
		t.Fatal(w.dump(r))
	}
}
