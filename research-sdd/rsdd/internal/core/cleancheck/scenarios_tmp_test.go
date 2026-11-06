package cleancheck

import "os"

// ageTmp creates tmp.<name> (a file, or a directory when dir) aged hours.
func ageTmp(w *world, name string, hours float64, dir bool) {
	p := w.tmp + "/" + name
	if dir {
		w.mkdir(p)
	} else {
		w.writeAt(p, "x")
	}
	w.ago(hours, p)
}

// tmpScenarios are the stale tmp.* cases (b).
func tmpScenarios() []scenario {
	return []scenario{
		{name: "stale-tmp-old-young-other-dir", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.old", 48, false)
			ageTmp(w, "tmp.young", 0.01, false)
			ageTmp(w, "other.old", 48, false)
			ageTmp(w, "tmp.dir", 72, true)
			ageTmp(w, "xtmp.old", 48, false)
		}, args: std(), want: 1},
		{name: "stale-tmp-boundary", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.not-yet", 24.005, false)
			ageTmp(w, "tmp.just-over", 24.05, false)
			ageTmp(w, "tmp.under", 23.9, false)
		}, args: std(), want: 1},
		{name: "stale-hours-zero", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.fresh", 0.001, false)
			ageTmp(w, "tmp.six-minutes", 0.1, false)
		}, args: std("--stale-hours", "0"), want: 1},
		{name: "stale-hours-leading-zero-is-decimal", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.nine", 9.5, false)
			ageTmp(w, "tmp.seven", 7.5, false)
		}, args: std("--stale-hours", "08"), want: 1},
		{name: "stale-hours-large", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.old", 48, false)
		}, args: std("--stale-hours", "999999999"), want: 0},
		{name: "stale-tmp-owned-by-another-uid", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.old", 48, false)
		}, args: std(), env: func(*world) []string { return []string{"CLEAN_CHECK_UID=" + uidPlusOne()} }, want: 0},
		{name: "stale-tmp-sorted-bytewise", build: func(w *world) {
			keep(w, "")
			for _, n := range []string{"tmp.b", "tmp.A", "tmp.a", "tmp.10", "tmp.9", "tmp.Z", "tmp._"} {
				ageTmp(w, n, 48, false)
			}
		}, args: std(), want: 1},
		{name: "stale-tmp-trailing-slash-on-tmp", build: func(w *world) { keep(w, ""); ageTmp(w, "tmp.old", 48, false) },
			args: func(w *world) []string { return []string{"--target", w.repo, "--tmp", w.tmp + "/"} }, want: 1},
		{name: "stale-tmp-symlink-entry", build: func(w *world) {
			keep(w, "")
			w.writeAt(w.root+"/real", "x")
			w.ago(48, w.root+"/real")
			if err := os.Symlink(w.root+"/real", w.tmp+"/tmp.link"); err != nil {
				w.t.Fatal(err)
			}
		}, args: std("--stale-hours", "1"), want: 0},
		{name: "stale-tmp-inside-scratchpad-is-exempt", build: func(w *world) {
			keep(w, "")
			ageTmp(w, "tmp.scratch", 48, true)
			ageTmp(w, "tmp.other", 48, false)
		}, args: func(w *world) []string {
			return []string{"--target", w.repo, "--tmp", w.tmp, "--scratchpad", w.tmp + "/tmp.scratch"}
		}, want: 1},
		{name: "stale-tmp-with-newline-in-name", build: func(w *world) { keep(w, ""); ageTmp(w, "tmp.a\nb", 48, false) }, args: std(), want: 1},
	}
}
