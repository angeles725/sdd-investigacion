package ensureremote

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Layer 4c through the whole command: the allow list, positive identification and the history walk. The
// classification rules themselves are pinned byte by byte in classify_test.go; these tests pin what the command
// DOES with a verdict (exit code, typed line, no push) and the order of the checks.

const conf = ".research-sdd/secret-files.conf"

func allowed(path string, line int, glob string, nblob int) string {
	return "ALLOWED: " + path + " (" + conf + ":" + itoa(line) + " allow " + glob + "; " + itoa(nblob) + " blob(s) positively public)\n"
}

func itoa(n int) string { return strconv.Itoa(n) }

func TestAllowSinglePublicDER(t *testing.T) {
	w := newWorld(t)
	w.conf("allow pub.der")
	w.track("pub.der", "spki")
	rc := w.ok()
	if rc != 0 || !w.pushed() || !strings.Contains(w.out(), allowed("pub.der", 1, "pub.der", 1)) || w.err() != "" {
		t.Errorf("rc=%d out=%q err=%q", rc, w.out(), w.err())
	}
	// the ALLOWED line is on stdout, before the creation banner
	if i, j := strings.Index(w.out(), "ALLOWED:"), strings.Index(w.out(), ">> creating"); i < 0 || i > j {
		t.Errorf("out = %q", w.out())
	}
}

func TestAllowListEdges(t *testing.T) {
	files := []string{"a.der", "dir/b.pem", "c.key"}
	for pos := 0; pos < 3; pos++ {
		w := newWorld(t)
		var lines []string
		for i, f := range files {
			w.track(f, "pempub")
			if i != pos {
				lines = append(lines, "allow "+f)
			}
		}
		w.conf(lines...)
		rc := w.ok()
		if rc != 5 || w.pushed() || !strings.Contains(w.err(), "would be pushed: "+files[pos]+"\n") || strings.Count(w.out(), "ALLOWED: ") != 2 {
			t.Errorf("pos %d: rc=%d out=%q err=%q", pos, rc, w.out(), w.err())
		}
	}
	w := newWorld(t)
	for _, f := range files {
		w.track(f, "pempub")
	}
	w.conf("allow a.der", "allow dir/b.pem", "allow c.key")
	if rc := w.ok(); rc != 0 || !w.pushed() || strings.Count(w.out(), "ALLOWED: ") != 3 {
		t.Errorf("all allowed: rc=%d out=%q", rc, w.out())
	}
}

func TestAllowIsNotABlanket(t *testing.T) {
	w := newWorld(t)
	w.conf("allow pub.der")
	w.track("pub.der", "spki")
	w.track("other.pem", "pempub")
	rc := w.ok()
	if rc != 5 || w.pushed() || !strings.Contains(w.err(), "would be pushed: other.pem\n") || strings.Contains(w.err(), "pub.der") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
	// the allowed file is still reported
	if !strings.Contains(w.out(), "ALLOWED: pub.der ") {
		t.Errorf("out = %q", w.out())
	}
}

func TestAllowStaleEntries(t *testing.T) {
	stale := func(line int, g string) string {
		return "STALE: " + conf + ":" + itoa(line) + " 'allow " + g + "' matches no refused tracked path — remove it.\n"
	}
	for _, tt := range []struct {
		name  string
		lines []string
		track bool
		stale string
	}{
		{"first", []string{"allow gone1.der", "allow pub.der"}, true, stale(1, "gone1.der")},
		{"middle", []string{"allow pub.der", "allow gone1.der", "allow pub.der"}, true, stale(2, "gone1.der")},
		{"last", []string{"allow pub.der", "allow gone1.der"}, true, stale(2, "gone1.der")},
		{"single", []string{"allow gone1.der"}, false, stale(1, "gone1.der")},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.conf(tt.lines...)
			if tt.track {
				w.track("pub.der", "spki")
			}
			rc := w.ok()
			if rc != 0 || w.err() != tt.stale {
				t.Errorf("rc=%d err=%q want %q", rc, w.err(), tt.stale)
			}
		})
	}
}

func TestAllowStaleIsNonFatalEvenWithARefusal(t *testing.T) {
	w := newWorld(t)
	w.conf("allow gone.der")
	w.track("x.pem", "pempub")
	rc := w.ok()
	if rc != 5 || !strings.HasPrefix(w.err(), "STALE: ") || !strings.Contains(w.err(), "REFUSED: secret-bearing") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestAllowFirstMatchNamesTheLineButEveryMatchingEntryIsLive(t *testing.T) {
	w := newWorld(t)
	w.conf("allow *.der", "allow pub.*")
	w.track("pub.der", "spki")
	rc := w.ok()
	if rc != 0 || !strings.Contains(w.out(), allowed("pub.der", 1, "*.der", 1)) || w.err() != "" {
		t.Errorf("rc=%d out=%q err=%q (the second entry also matched, so it is not stale)", rc, w.out(), w.err())
	}
}

func TestMalformedAllowListIsATypedConfigError(t *testing.T) {
	for _, tt := range []struct {
		lines []string
		line  int
		why   string
	}{
		{[]string{"frob"}, 1, "unknown directive 'frob'"},
		{[]string{"# c", "allow pub.der", "allow *"}, 3, "blanket glob '*' (needs at least one literal character)"},
		{[]string{"allow", "allow pub.der"}, 1, "'allow' needs a path glob"},
	} {
		w := newWorld(t)
		w.conf(tt.lines...)
		w.track("pub.der", "spki")
		rc := w.ok()
		want := "REFUSED: " + conf + ":" + itoa(tt.line) + ": " + tt.why + " — expected 'allow <path-glob>'.\n"
		if rc != 2 || w.err() != want || w.created() || w.pushed() {
			t.Errorf("rc=%d err=%q want %q", rc, w.err(), want)
		}
	}
}

func TestAllowConfNotARegularFile(t *testing.T) {
	w := newWorld(t)
	os.MkdirAll(filepath.Join(w.target, ".research-sdd", "secret-files.conf"), 0o755)
	rc := w.ok()
	want := "REFUSED: " + conf + " exists but is not a readable regular file — cannot read the allow list.\n"
	if rc != 7 || w.err() != want || w.created() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
	// a dangling symlink exists (-L) but is not a regular file either
	w = newWorld(t)
	os.MkdirAll(filepath.Join(w.target, ".research-sdd"), 0o755)
	os.Symlink(filepath.Join(w.root, "nowhere"), filepath.Join(w.target, ".research-sdd", "secret-files.conf"))
	if rc := w.ok(); rc != 7 || w.err() != want {
		t.Errorf("dangling: rc=%d err=%q", rc, w.err())
	}
}

func TestAllowConfIsReadBeforeAnyHistoryAndAfterTheScan(t *testing.T) {
	// a malformed list still waits for the dirty-tree and scanner layers: they run first
	w := newWorld(t)
	w.conf("frob")
	w.statusOut = "M x\n"
	if rc := w.ok(); rc != 8 {
		t.Errorf("rc=%d", rc)
	}
	w = newWorld(t)
	w.conf("frob")
	w.scanRC = 1
	if rc := w.ok(); rc != 5 || !strings.Contains(w.err(), "high-confidence secret VALUE") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestAllowPrivateKeyNeverAllowable(t *testing.T) {
	for _, kind := range []string{"pempriv", "pemenc", "pkcs8", "pkcs8s", "sec1", "pkcs1", "ppk", "age", "ssh2"} {
		t.Run(kind, func(t *testing.T) {
			w := newWorld(t)
			w.conf("allow k.der")
			w.track("k.der", kind)
			rc := w.ok()
			want := "REFUSED: allowed path(s) contain private key material or are keystore/identity files: k.der\n" +
				"         a private key can never be allowed — untrack it (git rm --cached) and cite it by structure + sha256.\n"
			if rc != 5 || w.pushed() || w.err() != want || strings.Contains(w.out(), "ALLOWED: k.der") {
				t.Errorf("rc=%d err=%q out=%q", rc, w.err(), w.out())
			}
		})
	}
	// list edge: the private key is the LAST of several allowed files
	w := newWorld(t)
	w.conf("allow *.der")
	w.track("a.der", "spki")
	w.track("b.der", "spki")
	w.track("c.der", "pkcs8")
	rc := w.ok()
	if rc != 5 || w.pushed() || !strings.Contains(w.err(), "files: c.der\n") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestAllowKeystoreTypesNeverAllowable(t *testing.T) {
	for _, nm := range []string{"store.p12", "id.pfx", "app.jks", "my.keystore", "id_rsa", "dir/id_rsa.pub", "dir/x.keystore"} {
		w := newWorld(t)
		w.conf("allow " + nm)
		w.track(nm, "pempub")
		rc := w.ok()
		if rc != 5 || w.pushed() || !strings.Contains(w.err(), "keystore/identity files: "+nm+"\n") {
			t.Errorf("%s: rc=%d err=%q", nm, rc, w.err())
		}
		// the history of a keystore-typed path is never even read
		if w.called(" log ") || w.called("cat-file") {
			t.Errorf("%s: history read for a keystore type: %v", nm, w.calls)
		}
	}
	// a keystore-typed name that is NOT allowed is plainly unallowed, not "private"
	w := newWorld(t)
	w.track("store.p12", "pempub")
	if rc := w.ok(); rc != 5 || !strings.Contains(w.err(), "git-TRACKED and would be pushed: store.p12") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestAllowGlobsCommentsBlanksAndSlashCrossing(t *testing.T) {
	w := newWorld(t)
	w.conf("# public assets", "", "allow licenses/*", "   allow   *.der   ")
	w.track("licenses/lic.txt", "pempub")
	w.track("deep/x/pub.der", "spki")
	rc := w.ok()
	if rc != 0 || strings.Count(w.out(), "ALLOWED: ") != 2 {
		t.Errorf("rc=%d out=%q err=%q", rc, w.out(), w.err())
	}
	// a comments-only list allows nothing
	w = newWorld(t)
	w.conf("# nothing allowed")
	w.track("pub.der", "spki")
	if rc := w.ok(); rc != 5 || w.pushed() {
		t.Errorf("comments-only: rc=%d", rc)
	}
}

func TestAllowCRLFList(t *testing.T) {
	w := newWorld(t)
	os.MkdirAll(filepath.Join(w.target, ".research-sdd"), 0o755)
	os.WriteFile(filepath.Join(w.target, conf), []byte("# c\r\nallow pub.der\r\n"), 0o644)
	w.track("pub.der", "spki")
	if rc := w.ok(); rc != 0 || !strings.Contains(w.out(), "ALLOWED: pub.der") {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

// Case 37 and 38 through the command: the verdict decides the exit code and the typed line.
func TestAllowVerdicts(t *testing.T) {
	notPub := "REFUSED (not positively public): "
	for _, tt := range []struct {
		rel, kind string
		rc        int
		line      string // a required stderr line prefix ("" = ALLOWED expected)
	}{
		{"x.pem", "pemcert", 0, ""}, {"x.pem", "pempub", 0, ""}, {"x.der", "cert", 0, ""}, {"x.der", "certv1", 0, ""},
		{"x.der", "spki", 0, ""}, {"x.der", "ed25519", 0, ""}, {"licenses/LICENSE", "licence", 0, ""},
		{"x.pem", "pemrsapub", 0, ""}, {"x.pem", "pemcrl", 0, ""}, {"licenses/APACHE", "licnormal", 0, ""},
		{"x.der", "encpk8", 5, notPub}, {"x.der", "p12", 5, notPub}, {"security/ks", "jks", 5, notPub},
		{"security/secring.gpg", "gpgsec", 5, notPub}, {"k.key", "rawb64", 5, notPub}, {"x.pem", "pemmixed", 5, notPub},
		{"x.der", "badoid", 5, notPub}, {"licenses/n.txt", "nulonly", 5, notPub}, {"licenses/c.txt", "ctrl", 5, notPub},
		{"licenses/s.txt", "secrettxt", 5, notPub}, {"x.pem", "relabel", 5, notPub}, {"x.pem", "certplus", 5, notPub},
		{"x.pem", "certhex", 5, notPub}, {"licenses/h.txt", "lichex", 5, notPub}, {"licenses/x.txt", "licxxd", 5, notPub},
		{"licenses/b.txt", "licb64", 5, notPub}, {"licenses/hs.txt", "lichexsp", 5, notPub}, {"licenses/r.txt", "licrun", 5, notPub},
		{"licenses/l.txt", "lfs", 5, "REFUSED (LFS pointer: content not inspectable): "},
		{"x.der", "ppk", 5, "REFUSED: allowed path(s) contain private key material"},
		{"k.key", "age", 5, "REFUSED: allowed path(s) contain private key material"},
		{"k.key", "ssh2", 5, "REFUSED: allowed path(s) contain private key material"},
		{"x.pem", "pempriv", 5, "REFUSED: allowed path(s) contain private key material"},
	} {
		t.Run(tt.kind, func(t *testing.T) {
			w := newWorld(t)
			w.conf("allow " + tt.rel)
			w.track(tt.rel, tt.kind)
			rc := w.ok()
			if rc != tt.rc {
				t.Fatalf("rc=%d out=%q err=%q", rc, w.out(), w.err())
			}
			if tt.rc == 0 {
				if !w.pushed() || !strings.Contains(w.out(), "ALLOWED: "+tt.rel+" ") {
					t.Errorf("out=%q", w.out())
				}
				return
			}
			if w.pushed() || strings.Contains(w.out(), "ALLOWED: ") || !strings.Contains(w.err(), tt.line) || !strings.Contains(w.err(), tt.rel) {
				t.Errorf("out=%q err=%q", w.out(), w.err())
			}
		})
	}
}

func TestAllowRefusalTexts(t *testing.T) {
	w := newWorld(t)
	w.conf("allow x.pem")
	w.track("x.pem", "pemmixed")
	w.ok()
	want := "REFUSED (not positively public): x.pem\n" +
		"         an allowed path must be positively identified as public (PEM cert/public key, DER cert/SPKI, licence text)\n" +
		"         in EVERY committed revision; anything else stays refused. Untrack it and cite it by structure + sha256.\n"
	if w.err() != want {
		t.Errorf("err = %q", w.err())
	}
	w = newWorld(t)
	w.conf("allow l.txt")
	w.track("l.txt", "lfs")
	w.ok()
	want = "REFUSED (LFS pointer: content not inspectable): l.txt\n" +
		"         the real content lives outside this repository's objects, so it cannot be shown to be public.\n"
	if w.err() != want {
		t.Errorf("err = %q", w.err())
	}
}

// The order of the final refusals: private material, then LFS pointers, then not-public, then unallowed.
func TestAllowRefusalPrecedence(t *testing.T) {
	setup := func(w *world) {
		w.conf("allow *.der")
		w.track("p.der", "pkcs8")
		w.track("l.der", "lfs")
		w.track("n.der", "badoid")
		w.track("u.pem", "pempub")
	}
	w := newWorld(t)
	setup(w)
	if rc := w.ok(); rc != 5 || !strings.Contains(w.err(), "private key material or are keystore/identity files: p.der\n") || strings.Contains(w.err(), "LFS") {
		t.Errorf("private first: rc=%d err=%q", rc, w.err())
	}
	w = newWorld(t)
	setup(w)
	w.tracked = []string{"l.der", "n.der", "u.pem"}
	w.ok()
	if !strings.HasPrefix(w.err(), "REFUSED (LFS pointer") || strings.Contains(w.err(), "not positively public") {
		t.Errorf("lfs second: err=%q", w.err())
	}
	w = newWorld(t)
	setup(w)
	w.tracked = []string{"n.der", "u.pem"}
	w.ok()
	if !strings.HasPrefix(w.err(), "REFUSED (not positively public): n.der") || strings.Contains(w.err(), "git-TRACKED") {
		t.Errorf("notpub third: err=%q", w.err())
	}
}

func TestAllowSeveralRefusedPathsAreListed(t *testing.T) {
	w := newWorld(t)
	w.conf("allow *.der")
	w.track("a.der", "badoid")
	w.track("b.der", "encpk8")
	w.ok()
	if !strings.Contains(w.err(), "REFUSED (not positively public): a.der\nREFUSED (not positively public): b.der\n") {
		t.Errorf("err = %q", w.err())
	}
}

// ---- history (case 39 to 43) ---------------------------------------------------------------------------------

func TestHistoryEveryBlobMustBePublic(t *testing.T) {
	for pos := 0; pos < 3; pos++ {
		w := newWorld(t)
		w.conf("allow k.der")
		kinds := []string{"cert", "cert", "cert"}
		kinds[pos] = "pkcs8"
		w.track("k.der", kinds...)
		rc := w.ok()
		if rc != 5 || w.pushed() || strings.Contains(w.out(), "ALLOWED: ") || !strings.Contains(w.err(), "k.der") {
			t.Errorf("revision %d: rc=%d out=%q err=%q", pos, rc, w.out(), w.err())
		}
	}
}

func TestHistoryOverwrittenPrivateKeyIsStillThere(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.track("k.der", "pkcs8", "cert") // the C1 shape: private committed, overwritten by a public cert
	if rc := w.ok(); rc != 5 || w.pushed() {
		t.Errorf("rc=%d", rc)
	}
}

func TestHistoryAllPublicIsAllowedAndCountsBlobs(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.track("k.der", "cert", "spki")
	rc := w.ok()
	// 3 distinct ids: the first revision's all-zero old side is skipped; revision 2's old is revision 1's new
	if rc != 0 || !strings.Contains(w.out(), allowed("k.der", 1, "k.der", 2)) {
		t.Errorf("rc=%d out=%q", rc, w.out())
	}
}

func TestHistoryReadsEveryRefAndMergedAwayBranches(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.pem")
	w.track("k.pem", "pempub")
	// a side branch merged away with `-s ours`: -m reports its private blob as another raw line
	w.rawLine("k.pem", w.blob(fixture(t, "pempub")), w.blob(fixture(t, "pempriv")))
	rc := w.ok()
	if rc != 5 || w.pushed() || strings.Contains(w.out(), "ALLOWED: ") {
		t.Errorf("rc=%d out=%q err=%q", rc, w.out(), w.err())
	}
	var log string
	for _, c := range w.calls {
		if strings.Contains(c, " log ") {
			log = c
		}
	}
	want := "git --literal-pathspecs -C " + w.target + " log --all -m --full-history --no-renames --format= --raw --no-abbrev -- k.pem"
	if log != want {
		t.Errorf("log argv:\n%s\nwant:\n%s", log, want)
	}
}

func TestHistoryPreImageIsClassifiedToo(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"}
	w.rawLine("k.der", w.blob(fixture(t, "pkcs8")), w.blob(fixture(t, "spki"))) // private only as the OLD side
	rc := w.ok()
	if rc != 5 || w.pushed() || strings.Contains(w.out(), "ALLOWED: ") {
		t.Errorf("rc=%d out=%q", rc, w.out())
	}
	// and the NEW side only
	w = newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"}
	w.rawLine("k.der", w.blob(fixture(t, "spki")), w.blob(fixture(t, "pkcs8")))
	if rc := w.ok(); rc != 5 {
		t.Errorf("new side: rc=%d", rc)
	}
}

func TestHistoryRepeatedBlobCountsOnce(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"}
	id := w.blob(fixture(t, "cert"))
	w.rawLine("k.der", id, id)
	w.rawLine("k.der", id, id)
	rc := w.ok()
	if rc != 0 || !strings.Contains(w.out(), allowed("k.der", 1, "k.der", 1)) {
		t.Errorf("rc=%d out=%q", rc, w.out())
	}
}

func TestHistoryGitFailureFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.track("k.der", "cert")
	w.logFail["k.der"] = true
	rc := w.ok()
	if rc != 7 || w.err() != "REFUSED: could not read the git history of 'k.der' (git log failed) — cannot verify it is public.\n" || w.pushed() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
}

func TestHistoryNoCommittedBlobFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"} // listed by git, no history at all
	rc := w.ok()
	if rc != 7 || w.err() != "REFUSED: no committed blob found for 'k.der' — cannot verify it is public.\n" || w.pushed() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
	// only all-zero ids: still no blob
	w = newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"}
	z := strings.Repeat("0", 40)
	w.rawLine("k.der", z, z)
	if rc := w.ok(); rc != 7 || !strings.Contains(w.err(), "no committed blob found") {
		t.Errorf("zero ids: rc=%d err=%q", rc, w.err())
	}
}

func TestHistoryUnreadableBlobFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.conf("allow ghost.der")
	w.tracked = []string{"ghost.der"}
	id := w.blob(fixture(t, "cert"))
	w.rawLine("ghost.der", strings.Repeat("0", 40), id)
	w.catFail[id] = true
	rc := w.ok()
	if rc != 7 || w.err() != "REFUSED: could not read blob "+id+" of 'ghost.der' (git cat-file failed) — cannot verify it is public.\n" || w.pushed() {
		t.Errorf("rc=%d err=%q", rc, w.err())
	}
	if !w.called("cat-file blob " + id) {
		t.Errorf("calls=%v", w.calls)
	}
}

func TestHistoryUnparseableLines(t *testing.T) {
	for _, tt := range []struct{ name, line string }{
		{"non-hex-old", ":100644 100644 XYZ " + strings.Repeat("a", 40) + " M\tk.der"},
		{"non-hex-new", ":100644 100644 " + strings.Repeat("a", 40) + " zz M\tk.der"},
		{"uppercase-hex", ":100644 100644 " + strings.Repeat("A", 40) + " " + strings.Repeat("a", 40) + " M\tk.der"},
		{"missing-fields", ":100644 100644"},
		{"missing-new", ":100644 100644 " + strings.Repeat("a", 40)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.conf("allow k.der")
			w.tracked = []string{"k.der"}
			w.blobs[strings.Repeat("a", 40)] = fixture(t, "cert") // the pre-image is read before the post-image is parsed
			w.history["k.der"] = []string{tt.line}
			rc := w.ok()
			if rc != 7 || w.err() != "REFUSED: unparseable git history for 'k.der' — cannot verify it is public.\n" {
				t.Errorf("rc=%d err=%q", rc, w.err())
			}
		})
	}
}

func TestHistoryIgnoresLinesThatAreNotRaw(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"}
	id := w.blob(fixture(t, "cert"))
	w.history["k.der"] = []string{"", "warning: something", ":100644 100644 " + strings.Repeat("0", 40) + " " + id + " A\tk.der", "  "}
	if rc := w.ok(); rc != 0 || !strings.Contains(w.out(), allowed("k.der", 1, "k.der", 1)) {
		t.Errorf("rc=%d out=%q err=%q", rc, w.out(), w.err())
	}
}

func TestHistoryStopsAtTheFirstBadBlobOfAPath(t *testing.T) {
	w := newWorld(t)
	w.conf("allow k.der")
	w.tracked = []string{"k.der"}
	w.commit("k.der", fixture(t, "pkcs8"))
	w.commit("k.der", fixture(t, "cert"))
	w.commit("k.der", fixture(t, "cert"))
	w.ok()
	if n := w.count("cat-file"); n != 1 {
		t.Errorf("cat-file calls = %d, want 1 (the walk stops at the first non-public blob): %v", n, w.calls)
	}
}

func TestHistoryNotReadForUnallowedPaths(t *testing.T) {
	w := newWorld(t)
	w.conf("allow other.der")
	w.track("k.pem", "pempub")
	w.ok()
	if w.called(" log ") || w.called("cat-file") {
		t.Errorf("history read for a path no entry allows: %v", w.calls)
	}
}

func TestNoAllowListMeansNoHistoryWalk(t *testing.T) {
	w := newWorld(t)
	w.ok()
	if w.called(" log ") || w.called("cat-file") {
		t.Errorf("calls=%v", w.calls)
	}
}
