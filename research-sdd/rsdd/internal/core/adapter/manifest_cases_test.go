//go:build linux

package adapter

import (
	"crypto/sha256"
	hexenc "encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// stdFixture builds the artifact tree of the retired analysis-manifest.test.sh.
func stdFixture(w *world) {
	w.bytes("sample.bin", []byte("input\x00bytes"), 0o644)
	w.file("bin/tool", "#!/bin/false\n", 0o700)
	w.file("tools/vineflower.jar", "jar bytes\n", 0o644)
	w.file("tools/plugin.jar", "plugin bytes\n", 0o644)
	w.file("evidence/stdout.txt", "finding\n", 0o644)
	w.file("evidence/stderr.txt", "", 0o644)
	w.file("outputs/result.txt", "result\n", 0o644)
}

func stdSpec(w *world) map[string]any {
	return map[string]any{
		"schema_version": "analysis-manifest.v1",
		"input":          map[string]any{"path": "sample.bin", "detected_type": "data"},
		"tool":           map[string]any{"name": "fixture", "version": "1.0", "executable": filepath.Join(w.root, "bin/tool"), "artifacts": []any{}},
		"argv":           []any{filepath.Join(w.root, "bin/tool"), "--inspect", "sample.bin"},
		"environment":    map[string]any{"LANG": "C.UTF-8", "TZ": "UTC"},
		"run":            map[string]any{"started_at": "2026-07-18T08:00:00Z", "ended_at": "2026-07-18T08:00:01Z", "duration_ms": 1000, "exit_code": 0, "signal": nil},
		"stdout_path":    "evidence/stdout.txt",
		"stderr_path":    "evidence/stderr.txt",
		"outputs":        []any{"outputs/result.txt"},
		"findings":       []any{map[string]any{"id": "F-1", "claim": "Observed fixture output", "evidence_locations": []any{"evidence/stdout.txt:1"}}},
		"limitations":    []any{}, "errors": []any{}, "completeness": "complete",
		"isolation_profile": map[string]any{"name": "wsl-static", "static_only": true, "network_access": false, "target_execution": false},
	}
}

func sub(m map[string]any, key string) map[string]any { return m[key].(map[string]any) }

// editSpec writes spec.json after applying edit to a fresh copy of the standard spec.
func (w *world) editSpec(name string, edit func(s map[string]any)) string {
	s := stdSpec(w)
	if edit != nil {
		edit(s)
	}
	w.json(name, s)
	return filepath.Join(w.root, name)
}

func (w *world) create(spec, out string, extra ...string) runResult {
	args := append([]string{"create", "--root", w.root, "--spec", spec, "--output", out}, extra...)
	return w.run(args...)
}

// reidentity recomputes the canonical identity of a manifest the way the contract defines it.
func reidentity(t *testing.T, m map[string]any) {
	t.Helper()
	b, _ := json.Marshal(m)
	var c map[string]any
	_ = json.Unmarshal(b, &c)
	delete(c, "identity")
	if run, ok := c["run"].(map[string]any); ok {
		delete(run, "started_at")
		delete(run, "ended_at")
		delete(run, "duration_ms")
	}
	enc, err := jsonout.CanonicalUnicode(c)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(enc)
	m["identity"] = "sha256:" + hexenc.EncodeToString(sum[:])
}

// editManifest creates the standard manifest, applies edit, optionally recomputes the identity and
// writes it under name.
func (w *world) editManifest(name string, reid bool, edit func(m map[string]any)) string {
	w.t.Helper()
	spec := w.editSpec("spec.json", nil)
	good := filepath.Join(w.root, "good.json")
	if r := w.create(spec, good); r.RC != 0 {
		w.t.Fatalf("the standard manifest must be creatable: %s", r.Err)
	}
	var m map[string]any
	if err := json.Unmarshal(w.read("good.json"), &m); err != nil {
		w.t.Fatal(err)
	}
	edit(m)
	if reid {
		reidentity(w.t, m)
	}
	w.json(name, m)
	return filepath.Join(w.root, name)
}

type scriptCase struct {
	name string
	run  func(w *world)
}

// createCases are specs edited once and then created, validated and verified.
func createCases() []scriptCase {
	var cs []scriptCase
	add := func(name string, edit func(w *world, s map[string]any)) {
		cs = append(cs, scriptCase{"create/" + name, func(w *world) {
			stdFixture(w)
			spec := w.editSpec("spec.json", func(s map[string]any) {
				if edit != nil {
					edit(w, s)
				}
			})
			out := filepath.Join(w.root, "out.json")
			if r := w.create(spec, out); r.RC == 0 {
				w.run("validate", out)
				w.run("verify", "--root", w.root, out)
			}
		}})
	}
	add("standard", nil)
	for _, v := range []any{"analysis-manifest.v2", 5, nil, []any{"x"}, map[string]any{"a": 1, "b": []any{}}, true, 1.5, "it's \"q\"", ""} {
		v := v
		add("schema-version", func(w *world, s map[string]any) { s["schema_version"] = v })
	}
	add("not-an-object", func(w *world, s map[string]any) { w.json("spec.json", []any{1}) })
	add("missing-key", func(w *world, s map[string]any) { delete(s, "findings") })
	add("missing-two-keys", func(w *world, s map[string]any) { delete(s, "findings"); delete(s, "errors") })
	add("extra-key", func(w *world, s map[string]any) { s["zzz"] = 1; s["aaa"] = 2 })
	add("input-not-object", func(w *world, s map[string]any) { s["input"] = "sample.bin" })
	add("input-missing-detected", func(w *world, s map[string]any) { delete(sub(s, "input"), "detected_type") })
	add("input-extra", func(w *world, s map[string]any) { sub(s, "input")["x"] = 1 })
	for _, v := range []any{nil, 5, "", "  ", "/abs", "../x", "sub/../sample.bin", "sample.bin/", "missing.bin", "outputs", "evidence/../sample.bin"} {
		v := v
		add("input-path", func(w *world, s map[string]any) { sub(s, "input")["path"] = v })
	}
	for _, v := range []any{nil, "", " ", 5, "text", "é"} {
		v := v
		add("detected-type", func(w *world, s map[string]any) { sub(s, "input")["detected_type"] = v })
	}
	add("tool-not-object", func(w *world, s map[string]any) { s["tool"] = []any{} })
	for _, k := range []string{"name", "version", "executable", "artifacts"} {
		k := k
		add("tool-missing-"+k, func(w *world, s map[string]any) { delete(sub(s, "tool"), k) })
	}
	add("tool-extra", func(w *world, s map[string]any) { sub(s, "tool")["x"] = 1 })
	for _, v := range []any{"", "  ", nil, 5} {
		v := v
		add("tool-name", func(w *world, s map[string]any) { sub(s, "tool")["name"] = v })
		add("tool-version", func(w *world, s map[string]any) { sub(s, "tool")["version"] = v })
		add("tool-executable", func(w *world, s map[string]any) { sub(s, "tool")["executable"] = v })
	}
	add("tool-artifacts-not-list", func(w *world, s map[string]any) { sub(s, "tool")["artifacts"] = map[string]any{} })
	add("tool-artifact-not-object", func(w *world, s map[string]any) { sub(s, "tool")["artifacts"] = []any{"tools/vineflower.jar"} })
	add("tool-artifact-extra-key", func(w *world, s map[string]any) {
		sub(s, "tool")["artifacts"] = []any{map[string]any{"path": "a", "argv_index": 1, "x": 1}}
	})
	for _, v := range []any{true, false, "2", 2.0, 2.5, -1, 0, 3, 4, json.Number("99999999999999999999"), nil, []any{2}} {
		v := v
		add("artifact-argv-index", func(w *world, s map[string]any) {
			s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", "tools/vineflower.jar"}
			sub(s, "tool")["artifacts"] = []any{map[string]any{"path": "tools/vineflower.jar", "argv_index": v}}
		})
	}
	for _, v := range []any{nil, 5, "", "tools/missing.jar", "/abs/none.jar", "//x", "tools/../tools/vineflower.jar", "tools", "tools/vineflower.jar/"} {
		v := v
		add("artifact-path", func(w *world, s map[string]any) {
			s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", v}
			sub(s, "tool")["artifacts"] = []any{map[string]any{"path": v, "argv_index": 2}}
		})
	}
	add("interpreted", func(w *world, s map[string]any) {
		s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", "tools/vineflower.jar", "--plugin", "tools/plugin.jar"}
		sub(s, "tool")["artifacts"] = []any{map[string]any{"path": "tools/plugin.jar", "argv_index": 4}, map[string]any{"path": "tools/vineflower.jar", "argv_index": 2}}
	})
	add("interpreted-duplicate-index", func(w *world, s map[string]any) {
		s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", "tools/vineflower.jar"}
		sub(s, "tool")["artifacts"] = []any{map[string]any{"path": "tools/vineflower.jar", "argv_index": 2}, map[string]any{"path": "tools/vineflower.jar", "argv_index": 2}}
	})
	add("interpreted-token-mismatch", func(w *world, s map[string]any) {
		s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", "tools/vineflower.jar"}
		sub(s, "tool")["artifacts"] = []any{map[string]any{"path": "tools/plugin.jar", "argv_index": 2}}
	})
	add("interpreted-symlink", func(w *world, s map[string]any) {
		w.symlink("tools/link.jar", filepath.Join(w.root, "tools/plugin.jar"))
		s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", "tools/link.jar"}
		sub(s, "tool")["artifacts"] = []any{map[string]any{"path": "tools/link.jar", "argv_index": 2}}
	})
	add("external-artifact", func(w *world, s map[string]any) {
		ext := filepath.Join(filepath.Dir(w.root), "external.jar")
		_ = os.WriteFile(ext, []byte("external jar\n"), 0o644)
		w.steps = append(w.steps, step{Kind: "write", Path: "{root}/../external.jar", Text: "external jar\n", Mode: 0o644})
		s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "-jar", ext}
		sub(s, "tool")["artifacts"] = []any{map[string]any{"path": ext, "argv_index": 2}}
	})
	for _, v := range []any{nil, 5, "", []any{}, []any{5}, []any{"tool", 5}, "tool", map[string]any{}} {
		v := v
		add("argv", func(w *world, s map[string]any) { s["argv"] = v })
	}
	add("argv-zero-mismatch", func(w *world, s map[string]any) { s["argv"] = []any{filepath.Join(w.root, "bin/other"), "x"} })
	add("argv-zero-bare-unresolved", func(w *world, s map[string]any) {
		s["argv"] = []any{"tool", "x"}
		sub(s, "tool")["executable"] = "tool"
	})
	for _, opt := range []string{"--token", "--client-secret", "--access-token", "--refresh-token", "--password-file", "--tokenize", "--passwd", "--api-key", "--cookie-jar"} {
		opt := opt
		add("argv-option"+opt, func(w *world, s map[string]any) {
			s["argv"] = []any{filepath.Join(w.root, "bin/tool"), opt, "do-not-disclose-this-value"}
			s["outputs"] = []any{}
		})
		add("argv-option-eq"+opt, func(w *world, s map[string]any) {
			s["argv"] = []any{filepath.Join(w.root, "bin/tool"), opt + "=do-not-disclose-this-value"}
			s["outputs"] = []any{}
		})
	}
	add("argv-secret-value", func(w *world, s map[string]any) {
		s["argv"] = []any{filepath.Join(w.root, "bin/tool"), "--token", "ghp_abcdefghijklmnopqrstuvwxyz1234567890"}
	})
	for _, env := range []any{map[string]any{"PASSWORD": "value"}, map[string]any{"LANG": "Bearer abc123"}, map[string]any{"LANG": "ghp_abcdefghijklmnopqrstuvwxyz1234567890"},
		map[string]any{"LANG": "xoxb-1234567890-secret"}, nil, []any{}, "LANG", map[string]any{"LANG": 5}, map[string]any{"FOO": "x"}, map[string]any{}} {
		env := env
		add("environment", func(w *world, s map[string]any) { s["environment"] = env })
	}
	// PATH resolution of a bare argv zero.
	pathCase := func(name string, pathValue any, tool string) {
		add("path-"+name, func(w *world, s map[string]any) {
			w.mkdir("emptydir")
			w.file("bin2/tool", "#!/bin/true\n", 0o700)
			w.file("bin/noexec", "x", 0o600)
			p := pathValue
			if str, ok := p.(string); ok {
				p = strings.ReplaceAll(str, "{root}", w.root)
			}
			sub(s, "tool")["executable"] = tool
			s["argv"] = []any{tool, "x"}
			s["environment"] = map[string]any{"PATH": p}
			s["outputs"] = []any{}
		})
	}
	pathCase("abs", "{root}/bin", "tool")
	pathCase("abs-second", "/nonexistent:{root}/bin", "tool")
	pathCase("missing-dir", "{root}/missing", "tool")
	pathCase("empty-entry", "", "tool")
	pathCase("empty-entry-colon", ":{root}/bin", "tool")
	pathCase("dot", ".", "tool")
	pathCase("relative-bin", "bin", "tool")
	pathCase("relative-bin-dot", "./bin", "tool")
	pathCase("relative-dotdot", "../elsewhere", "tool")
	pathCase("relative-escape-inner", "bin/..", "tool")
	pathCase("relative-double-slash", "bin//", "tool")
	pathCase("relative-then-abs", "bin2:{root}/bin", "tool")
	pathCase("relative-abs-both", "{root}/bin2:bin", "tool")
	pathCase("tilde-home", "~/bin", "tool")
	pathCase("tilde-user", "~nosuchuser_xyz/bin", "tool")
	pathCase("tilde-alone", "~", "tool")
	pathCase("not-a-file", "{root}/emptydir", "emptydir")
	pathCase("noexec", "{root}/bin", "noexec")
	pathCase("slash-in-name", "{root}/bin", "bin/tool")
	pathCase("slash-relative-name", "", "bin/tool")
	pathCase("dotdot-name", "{root}/bin", "..")
	pathCase("dot-name", "{root}/bin", ".")
	pathCase("backslash-name", "{root}/bin", "bin\\tool")
	pathCase("tilde-name", "{root}/bin", "~/bin/tool")
	pathCase("tilde-user-name", "{root}/bin", "~nosuchuser_xyz/tool")
	pathCase("nul-in-path", "{root}/bin\u0000x", "tool")
	pathCase("nul-in-name", "{root}/bin", "to\u0000ol")
	pathCase("unicode-name", "{root}/bin", "tööl")
	add("path-symlink-escape", func(w *world, s map[string]any) {
		w.symlink("outside-path", filepath.Dir(w.root))
		w.file("../tool", "#!/bin/true\n", 0o700)
		sub(s, "tool")["executable"] = "tool"
		s["argv"] = []any{"tool"}
		s["environment"] = map[string]any{"PATH": "outside-path"}
		s["outputs"] = []any{}
	})
	add("output-symlink-inside-root", func(w *world, s map[string]any) {
		w.symlink("outputs/inside-link", filepath.Join(w.root, "sample.bin"))
		s["outputs"] = []any{"outputs/inside-link"}
	})
	add("launcher-unrelated-to-argv-zero", func(w *world, s map[string]any) {
		w.file("bin/other", "#!/bin/true\n", 0o700)
		s["argv"] = []any{filepath.Join(w.root, "bin/other"), "--inspect", "sample.bin"}
	})
	add("launcher-symlink", func(w *world, s map[string]any) {
		w.symlink("bin/tool-link", filepath.Join(w.root, "bin/tool"))
		sub(s, "tool")["executable"] = filepath.Join(w.root, "bin/tool-link")
		s["argv"] = []any{filepath.Join(w.root, "bin/tool-link")}
		s["outputs"] = []any{}
	})
	add("launcher-relative", func(w *world, s map[string]any) {
		sub(s, "tool")["executable"] = "bin/tool"
		s["argv"] = []any{"bin/tool"}
		s["outputs"] = []any{}
	})
	add("launcher-relative-unsafe", func(w *world, s map[string]any) {
		sub(s, "tool")["executable"] = "bin/../bin/tool"
		s["argv"] = []any{"bin/../bin/tool"}
	})
	add("launcher-dir", func(w *world, s map[string]any) {
		sub(s, "tool")["executable"] = filepath.Join(w.root, "tools")
		s["argv"] = []any{filepath.Join(w.root, "tools")}
	})
	add("launcher-missing", func(w *world, s map[string]any) {
		sub(s, "tool")["executable"] = filepath.Join(w.root, "bin/none")
		s["argv"] = []any{filepath.Join(w.root, "bin/none")}
	})
	add("launcher-noexec", func(w *world, s map[string]any) {
		sub(s, "tool")["executable"] = filepath.Join(w.root, "tools/plugin.jar")
		s["argv"] = []any{filepath.Join(w.root, "tools/plugin.jar")}
	})
	add("launcher-dotdot-abs", func(w *world, s map[string]any) {
		p := filepath.Join(w.root, "tools") + "/../bin/tool"
		sub(s, "tool")["executable"] = p
		s["argv"] = []any{p}
	})
	add("launcher-claimed-differs-same-file", func(w *world, s map[string]any) {
		w.symlink("bin/alias", filepath.Join(w.root, "bin/tool"))
		sub(s, "tool")["executable"] = filepath.Join(w.root, "bin/alias")
	})
	// run
	runEdit := func(name string, edit func(r map[string]any)) {
		add("run-"+name, func(w *world, s map[string]any) { edit(sub(s, "run")) })
	}
	for _, f := range []string{"started_at", "ended_at", "duration_ms", "exit_code", "signal"} {
		f := f
		runEdit("missing-"+f, func(r map[string]any) { delete(r, f) })
	}
	runEdit("extra", func(r map[string]any) { r["x"] = 1 })
	for _, v := range []any{"2026-07-18T08:00:00", "2026-07-18T08:00:00+00:00", 5, nil, "", "Z", "garbage Z", "2026-07-18T08:00:00ZZ", "2026-07-18T08:00:00.5Z", "2026-07-18T08:00:61Z", "2026-02-30T08:00:00Z", "2026-07-18T08:00:00+01:00Z", "2026-07-18T08:00:00-0100Z"} {
		v := v
		runEdit("started", func(r map[string]any) { r["started_at"] = v })
		runEdit("ended", func(r map[string]any) { r["ended_at"] = v })
	}
	runEdit("ended-before", func(r map[string]any) { r["ended_at"] = "2026-07-18T07:59:59Z" })
	runEdit("equal", func(r map[string]any) { r["ended_at"] = r["started_at"] })
	for _, v := range []any{-1, 0, true, false, 1.5, 2.0, "1", nil, json.Number("99999999999999999999999")} {
		v := v
		runEdit("duration", func(r map[string]any) { r["duration_ms"] = v })
	}
	for _, p := range [][2]any{{nil, nil}, {1, 2}, {0, 9}, {-1, nil}, {nil, -1}, {nil, 9}, {nil, true}, {true, nil}, {1.5, nil}, {"1", nil}, {nil, json.Number("99999999999999999999")}, {255, nil}} {
		p := p
		runEdit("exit-signal", func(r map[string]any) { r["exit_code"], r["signal"] = p[0], p[1] })
	}
	add("run-not-object", func(w *world, s map[string]any) { s["run"] = nil })
	add("run-list", func(w *world, s map[string]any) { s["run"] = []any{} })
	add("run-string", func(w *world, s map[string]any) { s["run"] = "x" })
	add("run-number", func(w *world, s map[string]any) { s["run"] = 5 })
	add("run-empty-object", func(w *world, s map[string]any) { s["run"] = map[string]any{} })
	// evidence paths
	for _, k := range []string{"stdout_path", "stderr_path"} {
		k := k
		for _, v := range []any{nil, 5, "", "missing.txt", "../x", "/abs", "outputs", "outputs/result.txt"} {
			v := v
			add(k, func(w *world, s map[string]any) { s[k] = v })
		}
	}
	add("outputs-absolute", func(w *world, s map[string]any) { s["outputs"] = []any{filepath.Join(w.root, "outputs/result.txt")} })
	for _, o := range []any{nil, "outputs/result.txt", map[string]any{}, []any{5}, []any{nil}, []any{""}, []any{"outputs/result.txt", "outputs/result.txt"}, []any{"sample.bin"},
		[]any{"outputs/result.txt", "evidence/stdout.txt"}, []any{"evidence/stdout.txt", "outputs/result.txt"}, []any{"missing"}, []any{"outputs"}, []any{"%2e%2e/escape"}, []any{"a:b"}} {
		o := o
		add("outputs", func(w *world, s map[string]any) { s["outputs"] = o })
	}
	// findings
	finding := func(id, claim any, locs any) map[string]any {
		return map[string]any{"id": id, "claim": claim, "evidence_locations": locs}
	}
	for _, f := range []any{nil, "x", map[string]any{}, []any{}, []any{5}, []any{[]any{}}, []any{map[string]any{"id": "a"}},
		[]any{finding("", "c", []any{"evidence/stdout.txt:1"})}, []any{finding("a", " ", []any{"evidence/stdout.txt:1"})}, []any{finding(5, "c", []any{"evidence/stdout.txt:1"})},
		[]any{finding("a", "c", []any{})}, []any{finding("a", "c", "evidence/stdout.txt:1")}, []any{finding("a", "c", nil)},
		[]any{finding("a", "c", []any{"evidence/stdout.txt:3-2"})}, []any{finding("a", "c", []any{"evidence/stdout.txt:0"})}, []any{finding("a", "c", []any{"nothing.txt:1"})},
		[]any{finding("a", "c", []any{"sample.bin:1"})}, []any{finding("a", "c", []any{"outputs/result.txt:1-1"})}, []any{finding("a", "c", []any{"evidence/stdout.txt:99"})},
		[]any{finding("a", "c", []any{"evidence/stdout.txt:99999999999999999999999"})}, []any{finding("a", "c", []any{5})}, []any{finding("a", "c", []any{"../x:1"})},
		[]any{finding("b", "c", []any{"evidence/stdout.txt:1"}), finding("a", "c", []any{"evidence/stdout.txt:1"})},
		[]any{finding("é", "c", []any{"evidence/stdout.txt:1"}), finding("z", "c", []any{"evidence/stdout.txt:1"}), finding("Z", "c", []any{"evidence/stdout.txt:1"})},
		[]any{finding("a", "c", []any{"evidence/stdout.txt:1"}), finding("a", "d", []any{"evidence/stdout.txt:1"})},
		[]any{finding("a", "c", []any{"evidence/stdout.txt:1", "outputs/result.txt:1"})},
		[]any{map[string]any{"id": "a", "claim": "c", "evidence_locations": []any{"evidence/stdout.txt:1"}, "extra": 1}},
		[]any{finding("a", "c", []any{"evidence/stdout.txt:1-1"})}, []any{finding("a", "c", []any{"evidence/stderr.txt:1"})}, []any{finding("a", "c", []any{"tools/vineflower.jar:1"})},
	} {
		f := f
		add("findings", func(w *world, s map[string]any) { s["findings"] = f })
	}
	for _, v := range []any{nil, "x", []any{5}, []any{""}, []any{" "}, []any{"ok", nil}, []any{"a limitation"}, map[string]any{}, []any{"é", "b"}} {
		v := v
		add("limitations", func(w *world, s map[string]any) { s["limitations"] = v })
		add("errors", func(w *world, s map[string]any) { s["errors"] = v })
	}
	for _, v := range []any{"partial", "failed", "complete", "Complete", "", nil, 5, []any{}} {
		v := v
		add("completeness", func(w *world, s map[string]any) { s["completeness"] = v })
	}
	for _, v := range []any{nil, "x", []any{}, map[string]any{}, map[string]any{"name": "n"}, map[string]any{"name": "", "static_only": true, "network_access": false, "target_execution": false},
		map[string]any{"name": 5, "static_only": true, "network_access": false, "target_execution": false}, map[string]any{"name": "n", "static_only": 1, "network_access": false, "target_execution": false},
		map[string]any{"name": "n", "static_only": true, "network_access": "no", "target_execution": false}, map[string]any{"name": "n", "static_only": true, "network_access": false, "target_execution": true},
		map[string]any{"name": "n", "static_only": true, "network_access": false, "target_execution": nil}, map[string]any{"name": "n", "static_only": false, "network_access": true, "target_execution": false},
		map[string]any{"name": "n", "static_only": true, "network_access": false, "target_execution": false, "x": 1}} {
		v := v
		add("isolation", func(w *world, s map[string]any) { s["isolation_profile"] = v })
	}
	return cs
}

// manifestCases edit a created manifest and then validate and verify it.
func manifestCases(t *testing.T) []scriptCase {
	var cs []scriptCase
	add := func(name string, reid bool, edit func(m map[string]any)) {
		cs = append(cs, scriptCase{"manifest/" + name, func(w *world) {
			stdFixture(w)
			p := w.editManifest("m.json", reid, edit)
			w.run("validate", p)
			w.run("verify", "--root", w.root, p)
		}})
	}
	add("untouched", false, func(m map[string]any) {})
	add("bad-hash", false, func(m map[string]any) { sub(m, "input")["sha256"] = "sha256:bad" })
	add("schema", false, func(m map[string]any) { m["schema_version"] = "analysis-manifest.v2" })
	add("missing-isolation", false, func(m map[string]any) { delete(m, "isolation_profile") })
	add("identity-not-str", false, func(m map[string]any) { m["identity"] = 5 })
	add("identity-wrong", false, func(m map[string]any) { m["identity"] = "sha256:" + strings.Repeat("0", 64) })
	add("identity-upper", false, func(m map[string]any) { m["identity"] = "sha256:" + strings.Repeat("A", 64) })
	add("identity-newline", false, func(m map[string]any) { m["identity"] = "sha256:" + strings.Repeat("0", 64) + "\n" })
	add("launcher-sha-null", true, func(m map[string]any) { sub(sub(m, "tool"), "launcher")["sha256"] = nil })
	add("launcher-sha-bad", true, func(m map[string]any) { sub(sub(m, "tool"), "launcher")["sha256"] = "sha256:xyz" })
	add("launcher-extra", true, func(m map[string]any) { sub(sub(m, "tool"), "launcher")["x"] = 1 })
	add("launcher-unrelated", true, func(m map[string]any) {
		sub(sub(m, "tool"), "launcher")["resolved_executable"] = "/usr/bin/env"
	})
	add("path-launcher-in-missing-dir", true, func(m map[string]any) {
		m["argv"].([]any)[0] = "tool"
		m["environment"] = map[string]any{"PATH": "/no-such-dir/bin:relative/dir"}
		sub(sub(m, "tool"), "launcher")["resolved_executable"] = "/no-such-dir/bin/tool"
	})
	add("launcher-exec-empty", true, func(m map[string]any) { sub(sub(m, "tool"), "launcher")["resolved_executable"] = "" })
	add("launcher-exec-relative-bad", true, func(m map[string]any) { sub(sub(m, "tool"), "launcher")["resolved_executable"] = "../x" })
	add("tool-name-blank", true, func(m map[string]any) { sub(m, "tool")["name"] = " " })
	add("tool-version-int", true, func(m map[string]any) { sub(m, "tool")["version"] = 1 })
	add("tool-artifacts-not-list", true, func(m map[string]any) { sub(m, "tool")["artifacts"] = nil })
	add("outputs-not-list", true, func(m map[string]any) { m["outputs"] = nil })
	add("output-extra-key", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["x"] = 1 })
	add("output-negative-size", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["size"] = -1 })
	add("output-bool-size", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["size"] = true })
	add("output-float-size", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["size"] = 1.5 })
	add("output-size-wrong", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["size"] = 99 })
	add("output-sha-wrong", true, func(m map[string]any) {
		m["outputs"].([]any)[0].(map[string]any)["sha256"] = "sha256:" + strings.Repeat("1", 64)
	})
	add("output-path-bad", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["path"] = "../x" })
	add("output-path-missing", true, func(m map[string]any) { m["outputs"].([]any)[0].(map[string]any)["path"] = "outputs/none.txt" })
	add("stdout-extra", true, func(m map[string]any) { sub(m, "stdout")["x"] = 1 })
	add("stdout-missing-key", true, func(m map[string]any) { delete(sub(m, "stdout"), "size") })
	add("input-name-wrong", true, func(m map[string]any) { sub(m, "input")["name"] = "other" })
	add("input-detected-blank", true, func(m map[string]any) { sub(m, "input")["detected_type"] = " " })
	add("input-detected-null", true, func(m map[string]any) { sub(m, "input")["detected_type"] = nil })
	add("input-detected-int", true, func(m map[string]any) { sub(m, "input")["detected_type"] = 3 })
	add("argv-secret", true, func(m map[string]any) { m["argv"] = []any{m["argv"].([]any)[0], "--password", "x"} })
	add("argv-zero-slash-mismatch", true, func(m map[string]any) { m["argv"] = []any{"/other/tool"} })
	add("argv-zero-bare-path-coherent", true, func(m map[string]any) {
		m["argv"] = []any{"tool"}
		m["environment"] = map[string]any{"PATH": filepath.Dir(sub(sub(m, "tool"), "launcher")["resolved_executable"].(string))}
	})
	add("argv-zero-bare-name-mismatch", true, func(m map[string]any) {
		m["argv"] = []any{"other"}
		m["environment"] = map[string]any{"PATH": filepath.Dir(sub(sub(m, "tool"), "launcher")["resolved_executable"].(string))}
	})
	add("argv-zero-bare-path-relative", true, func(m map[string]any) {
		m["argv"] = []any{"tool"}
		m["environment"] = map[string]any{"PATH": "bin"}
	})
	add("argv-zero-bare-path-other-dir", true, func(m map[string]any) {
		m["argv"] = []any{"tool"}
		m["environment"] = map[string]any{"PATH": "/nonexistent-dir"}
	})
	add("argv-zero-bare-env-list", true, func(m map[string]any) { m["argv"] = []any{"tool"}; m["environment"] = []any{} })
	add("argv-zero-bare-env-null", true, func(m map[string]any) { m["argv"] = []any{"tool"}; m["environment"] = nil })
	add("argv-zero-bare-path-int", true, func(m map[string]any) { m["argv"] = []any{"tool"}; m["environment"] = map[string]any{"PATH": 5} })
	add("argv-zero-bare-path-trailing-slash", true, func(m map[string]any) {
		m["argv"] = []any{"tool"}
		m["environment"] = map[string]any{"PATH": filepath.Dir(sub(sub(m, "tool"), "launcher")["resolved_executable"].(string)) + "/"}
	})
	add("argv-zero-bare-path-dotdot", true, func(m map[string]any) {
		m["argv"] = []any{"tool"}
		m["environment"] = map[string]any{"PATH": filepath.Dir(sub(sub(m, "tool"), "launcher")["resolved_executable"].(string)) + "/../bin"}
	})
	add("env-secret", true, func(m map[string]any) { m["environment"] = map[string]any{"LANG": "Bearer abc"} })
	add("env-not-allowlisted", true, func(m map[string]any) { m["environment"] = map[string]any{"FOO": "x"} })
	add("env-list", true, func(m map[string]any) { m["environment"] = []any{} })
	for _, f := range []string{"started_at", "ended_at", "duration_ms", "exit_code", "signal"} {
		f := f
		add("run-missing-"+f, true, func(m map[string]any) { delete(sub(m, "run"), f) })
	}
	add("run-naive", true, func(m map[string]any) { sub(m, "run")["started_at"] = "2026-07-18T08:00:00" })
	add("run-ended-before", true, func(m map[string]any) { sub(m, "run")["ended_at"] = "2026-07-18T07:00:00Z" })
	add("run-not-utc-zulu", true, func(m map[string]any) { sub(m, "run")["started_at"] = "2026-07-18T09:00:00+01:00" })
	add("run-both", true, func(m map[string]any) { sub(m, "run")["signal"] = 9 })
	add("run-signal", true, func(m map[string]any) { sub(m, "run")["exit_code"] = nil; sub(m, "run")["signal"] = 9 })
	add("run-negative-duration", true, func(m map[string]any) { sub(m, "run")["duration_ms"] = -1 })
	add("run-bool-exit", true, func(m map[string]any) { sub(m, "run")["exit_code"] = false })
	add("run-timing-changes-identity-not", false, func(m map[string]any) { sub(m, "run")["duration_ms"] = 5 })
	add("run-timing-changes-ids", false, func(m map[string]any) { sub(m, "run")["exit_code"] = 3 })
	add("finding-dup", true, func(m map[string]any) { m["findings"] = append(m["findings"].([]any), m["findings"].([]any)[0]) })
	add("finding-unbound", true, func(m map[string]any) {
		m["findings"].([]any)[0].(map[string]any)["evidence_locations"] = []any{"nowhere:1"}
	})
	add("finding-range-reversed", true, func(m map[string]any) {
		m["findings"].([]any)[0].(map[string]any)["evidence_locations"] = []any{"evidence/stdout.txt:3-2"}
	})
	add("finding-beyond-lines", true, func(m map[string]any) {
		m["findings"].([]any)[0].(map[string]any)["evidence_locations"] = []any{"evidence/stdout.txt:2"}
	})
	add("finding-last-line", true, func(m map[string]any) {
		m["findings"].([]any)[0].(map[string]any)["evidence_locations"] = []any{"evidence/stdout.txt:1-1"}
	})
	add("finding-on-input", true, func(m map[string]any) {
		m["findings"].([]any)[0].(map[string]any)["evidence_locations"] = []any{"sample.bin:1-2"}
	})
	add("finding-not-list", true, func(m map[string]any) { m["findings"] = nil })
	add("finding-id-blank", true, func(m map[string]any) { m["findings"].([]any)[0].(map[string]any)["id"] = "" })
	add("finding-claim-int", true, func(m map[string]any) { m["findings"].([]any)[0].(map[string]any)["claim"] = 5 })
	add("finding-locs-empty", true, func(m map[string]any) { m["findings"].([]any)[0].(map[string]any)["evidence_locations"] = []any{} })
	add("limitations-int", true, func(m map[string]any) { m["limitations"] = 5 })
	add("errors-blank", true, func(m map[string]any) { m["errors"] = []any{" "} })
	add("completeness-bad", true, func(m map[string]any) { m["completeness"] = "done" })
	add("isolation-exec", true, func(m map[string]any) { sub(m, "isolation_profile")["target_execution"] = true })
	add("isolation-int", true, func(m map[string]any) { sub(m, "isolation_profile")["static_only"] = 1 })
	add("isolation-extra", true, func(m map[string]any) { sub(m, "isolation_profile")["x"] = 1 })
	add("isolation-name-blank", true, func(m map[string]any) { sub(m, "isolation_profile")["name"] = "  " })
	add("extra-top", true, func(m map[string]any) { m["extra"] = 1 })
	add("tool-artifact-bad-index", true, func(m map[string]any) {
		sub(m, "tool")["artifacts"] = []any{map[string]any{"path": "tools/plugin.jar", "size": 1, "sha256": "sha256:" + strings.Repeat("0", 64), "argv_index": 7}}
	})
	add("tool-artifact-rehash", true, func(m map[string]any) {
		m["argv"] = []any{m["argv"].([]any)[0], "tools/plugin.jar"}
		sub(m, "tool")["artifacts"] = []any{map[string]any{"path": "tools/plugin.jar", "size": 13, "sha256": "sha256:" + hexSum("plugin bytes\n"), "argv_index": 1}}
	})
	add("tool-artifact-wrong-size", true, func(m map[string]any) {
		m["argv"] = []any{m["argv"].([]any)[0], "tools/plugin.jar"}
		sub(m, "tool")["artifacts"] = []any{map[string]any{"path": "tools/plugin.jar", "size": 3, "sha256": "sha256:" + hexSum("plugin bytes\n"), "argv_index": 1}}
	})
	// verify after the world changes
	mutate := func(name string, f func(w *world)) {
		cs = append(cs, scriptCase{"verify/" + name, func(w *world) {
			stdFixture(w)
			p := w.editManifest("m.json", false, func(m map[string]any) {})
			w.run("verify", "--root", w.root, p)
			f(w)
			w.run("validate", p)
			w.run("verify", "--root", w.root, p)
		}})
	}
	mutate("output-modified", func(w *world) { w.file("outputs/result.txt", "modified\n", 0o644) })
	mutate("input-modified", func(w *world) { w.bytes("sample.bin", []byte("x"), 0o644) })
	mutate("stdout-modified", func(w *world) { w.file("evidence/stdout.txt", "changed\n", 0o644) })
	mutate("tool-modified", func(w *world) { w.file("bin/tool", "#!/bin/true\n", 0o700) })
	mutate("tool-not-executable", func(w *world) { w.chmod("bin/tool", 0o600) })
	mutate("output-removed", func(w *world) { w.remove("outputs/result.txt") })
	mutate("output-now-symlink", func(w *world) {
		w.remove("outputs/result.txt")
		w.symlink("outputs/result.txt", filepath.Join(w.root, "sample.bin"))
	})
	mutate("input-now-dir", func(w *world) { w.remove("sample.bin"); w.mkdir("sample.bin") })
	mutate("stdout-now-longer", func(w *world) { w.file("evidence/stdout.txt", "finding\nmore\n", 0o644) })
	mutate("stdout-no-final-newline", func(w *world) { w.file("evidence/stdout.txt", "finding", 0o644) })
	mutate("root-other", func(w *world) {})
	return cs
}

func hexSum(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hexenc.EncodeToString(sum[:])
}
