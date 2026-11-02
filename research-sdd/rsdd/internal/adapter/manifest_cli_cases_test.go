//go:build linux

package adapter

import (
	"path/filepath"
	"strings"
)

func miscCases() []scriptCase {
	var cs []scriptCase
	add := func(name string, run func(w *world)) { cs = append(cs, scriptCase{"misc/" + name, run}) }

	add("create-twice-then-overwrite", func(w *world) {
		stdFixture(w)
		spec := w.editSpec("spec.json", func(s map[string]any) { s["outputs"] = []any{} })
		out := filepath.Join(w.root, "atomic.json")
		w.create(spec, out)
		w.create(spec, out)
		w.create(spec, out, "--overwrite")
		w.run("create", "--overwrite", "--root", w.root, "--spec", spec, "--output", out)
		w.run("validate", out)
	})
	add("overwrite-keeps-mode-of-new-file", func(w *world) {
		stdFixture(w)
		spec := w.editSpec("spec.json", nil)
		w.file("out.json", "old", 0o644)
		w.create(spec, filepath.Join(w.root, "out.json"), "--overwrite")
	})
	add("output-dir-missing", func(w *world) {
		stdFixture(w)
		w.create(w.editSpec("spec.json", nil), filepath.Join(w.root, "nodir/out.json"))
	})
	add("output-is-directory", func(w *world) {
		stdFixture(w)
		w.mkdir("outdir")
		spec := w.editSpec("spec.json", nil)
		w.create(spec, filepath.Join(w.root, "outdir"))
		w.create(spec, filepath.Join(w.root, "outdir"), "--overwrite")
	})
	add("output-is-symlink", func(w *world) {
		stdFixture(w)
		w.symlink("link.json", filepath.Join(w.root, "target.json"))
		spec := w.editSpec("spec.json", nil)
		w.create(spec, filepath.Join(w.root, "link.json"))
		w.create(spec, filepath.Join(w.root, "link.json"), "--overwrite")
	})
	add("output-in-symlinked-dir", func(w *world) {
		stdFixture(w)
		w.mkdir("real")
		w.symlink("alias", filepath.Join(w.root, "real"))
		w.create(w.editSpec("spec.json", nil), filepath.Join(w.root, "alias/out.json"))
	})
	add("output-relative-and-cwd", func(w *world) {
		stdFixture(w)
		w.editSpec("spec.json", nil)
		w.run("create", "--root", ".", "--spec", "spec.json", "--output", "out.json")
		w.run("validate", "out.json")
		w.run("verify", "--root", ".", "out.json")
		w.run("verify", "--root", "./", "./out.json")
		w.run("verify", "--root", "sub/..", "out.json")
	})
	add("relative-root-from-subdir", func(w *world) {
		stdFixture(w)
		w.mkdir("sub")
		w.editSpec("spec.json", nil)
		w.cwd = filepath.Join(w.root, "sub")
		w.run("create", "--root", "..", "--spec", "../spec.json", "--output", "out.json")
		w.run("verify", "--root", "..", "out.json")
		w.run("validate", "out.json")
	})
	add("root-missing", func(w *world) {
		stdFixture(w)
		w.run("create", "--root", filepath.Join(w.root, "nothing"), "--spec", w.editSpec("spec.json", nil), "--output", filepath.Join(w.root, "o.json"))
	})
	add("root-is-file", func(w *world) {
		stdFixture(w)
		w.run("create", "--root", filepath.Join(w.root, "sample.bin"), "--spec", w.editSpec("spec.json", nil), "--output", filepath.Join(w.root, "o.json"))
	})
	add("root-symlink", func(w *world) {
		stdFixture(w)
		w.symlink("rootlink", w.root)
		spec := w.editSpec("spec.json", nil)
		w.run("create", "--root", filepath.Join(w.root, "rootlink"), "--spec", spec, "--output", filepath.Join(w.root, "o.json"))
		w.run("verify", "--root", filepath.Join(w.root, "rootlink"), filepath.Join(w.root, "o.json"))
	})
	add("spec-missing", func(w *world) {
		stdFixture(w)
		w.run("create", "--root", w.root, "--spec", filepath.Join(w.root, "none.json"), "--output", filepath.Join(w.root, "o.json"))
		w.run("validate", filepath.Join(w.root, "none.json"))
		w.run("verify", "--root", w.root, filepath.Join(w.root, "none.json"))
		w.run("validate", "none.json")
		w.run("validate", "sub//none.json")
		w.run("validate", "./none.json")
		w.run("validate", "")
		w.run("validate", ".")
		w.run("validate", w.root)
	})
	add("spec-not-readable", func(w *world) {
		stdFixture(w)
		w.file("unreadable.json", "{}", 0o000)
		w.run("validate", filepath.Join(w.root, "unreadable.json"))
	})
	for name, body := range map[string]string{
		"empty": "", "spaces": "   \n", "bom": "\ufeff{}", "null": "null", "list": "[]", "string": `"x"`, "number": "5", "trailing": "{} x", "double": "{}{}",
		"crlf-error": "{\r\n \"a\": 1,\r\n \"b\": ,\r\n}", "cr-error": "{\r \"a\": ,\r}", "lf-error": "{\n\n\n x}", "trailing-comma": `{"a":1,}`, "unterminated": `{"a": "x`,
		"bigint": `{"schema_version": ` + strings.Repeat("9", 4400) + `}`, "deep": strings.Repeat("[", 50) + strings.Repeat("]", 50),
		"multibyte-error": "{\"é😀\": ,}", "tabs": "\t{\t}\t", "control": "{\"a\": \"\x01\"}",
	} {
		body := body
		add("spec-text-"+name, func(w *world) {
			stdFixture(w)
			w.file("spec.json", body, 0o644)
			w.run("create", "--root", w.root, "--spec", filepath.Join(w.root, "spec.json"), "--output", filepath.Join(w.root, "o.json"))
			w.run("validate", filepath.Join(w.root, "spec.json"))
			w.run("verify", "--root", w.root, filepath.Join(w.root, "spec.json"))
		})
	}
	for name, body := range map[string][]byte{"latin1": {0x7b, 0xe9, 0x7d}, "truncated-seq": {0x7b, 0xe2, 0x82}, "lone-continuation": {0x80}, "bad-start": {0xff, 0x7b}, "overlong": {0xc0, 0xaf},
		"surrogate-bytes": {0xed, 0xa0, 0x80}, "four-byte-bad": {0xf0, 0x28, 0x8c, 0xbc}, "e0-bad-second": {0xe0, 0x80, 0x80}, "f4-too-big": {0xf4, 0x90, 0x80, 0x80}, "valid-then-bad": {0x7b, 0x7d, 0xc3},
		"three-byte-bad-third": {0xe2, 0x82, 0x41}, "f8": {0xf8, 0x88, 0x80, 0x80, 0x80}} {
		body := body
		add("spec-bytes-"+name, func(w *world) {
			stdFixture(w)
			w.bytes("spec.json", body, 0o644)
			w.run("validate", filepath.Join(w.root, "spec.json"))
		})
	}
	add("duplicate-keys-last-wins", func(w *world) {
		stdFixture(w)
		spec := w.editSpec("spec.json", nil)
		text := string(w.read("spec.json"))
		w.file("spec.json", strings.Replace(text, `"completeness":"complete"`, `"completeness":"failed","completeness":"complete"`, 1), 0o644)
		w.create(spec, filepath.Join(w.root, "o.json"))
		w.file("spec2.json", strings.Replace(text, `"completeness":"complete"`, `"completeness":"complete","completeness":"nope"`, 1), 0o644)
		w.create(filepath.Join(w.root, "spec2.json"), filepath.Join(w.root, "o2.json"))
	})
	add("non-ascii-content", func(w *world) {
		stdFixture(w)
		w.bytes("évidence.bin", []byte("é\n"), 0o644)
		spec := w.editSpec("spec.json", func(s map[string]any) {
			s["outputs"] = []any{"évidence.bin"}
			s["findings"] = []any{map[string]any{"id": "é😀", "claim": "clâim   line", "evidence_locations": []any{"évidence.bin:1"}}}
			s["limitations"] = []any{"<limit> & \"quote\" \\ \u007f \u0001"}
		})
		out := filepath.Join(w.root, "o.json")
		w.create(spec, out)
		w.run("validate", out)
		w.run("verify", "--root", w.root, out)
	})
	add("big-numbers-survive", func(w *world) {
		stdFixture(w)
		w.editSpec("base.json", nil)
		text := string(w.read("base.json"))
		w.file("spec.json", strings.Replace(text, `"duration_ms":1000`, `"duration_ms":123456789012345678901234567890`, 1), 0o644)
		out := filepath.Join(w.root, "o.json")
		w.create(filepath.Join(w.root, "spec.json"), out)
		w.run("validate", out)
		w.file("spec3.json", strings.Replace(text, `"exit_code":0`, `"exit_code":-0`, 1), 0o644)
		w.create(filepath.Join(w.root, "spec3.json"), filepath.Join(w.root, "o3.json"))
		w.file("spec4.json", strings.Replace(text, `"duration_ms":1000`, `"duration_ms":1e3`, 1), 0o644)
		w.create(filepath.Join(w.root, "spec4.json"), filepath.Join(w.root, "o4.json"))
	})
	add("input-is-fifo-free-dir-and-special", func(w *world) {
		stdFixture(w)
		for _, in := range []string{"/dev/null", "/proc/self/status", "evidence"} {
			w.create(w.editSpec("spec.json", func(s map[string]any) { sub(s, "input")["path"] = in }), filepath.Join(w.root, "o.json"))
		}
	})
	add("output-path-dotted-names", func(w *world) {
		stdFixture(w)
		spec := w.editSpec("spec.json", nil)
		w.create(spec, filepath.Join(w.root, ".hidden.json"))
		w.create(spec, filepath.Join(w.root, "a b.json"))
		w.create(spec, filepath.Join(w.root, ".x.json.tmp"))
		w.create(spec, filepath.Join(w.root, ".x.json.tmp"), "--overwrite")
	})
	add("tilde-expands-home", func(w *world) {
		stdFixture(w)
		w.file("home/bin/tool", "#!/bin/false\n", 0o700)
		w.env["HOME"] = filepath.Join(w.root, "home")
		spec := w.editSpec("spec.json", func(s map[string]any) {
			sub(s, "tool")["executable"] = "tool"
			s["argv"] = []any{"tool"}
			s["environment"] = map[string]any{"PATH": "~/bin"}
			s["outputs"] = []any{}
		})
		out := filepath.Join(w.root, "o.json")
		w.create(spec, out)
		w.run("validate", out)
		w.run("verify", "--root", w.root, out)
		w.env["HOME"] = filepath.Join(w.root, "elsewhere")
		w.run("verify", "--root", w.root, out)
	})
	add("tilde-home-variants", func(w *world) {
		stdFixture(w)
		w.file("home/bin/tool", "#!/bin/false\n", 0o700)
		for _, home := range []string{filepath.Join(w.root, "home") + "/", filepath.Join(w.root, "home") + "//", "", "relative/home"} {
			w.env["HOME"] = home
			spec := w.editSpec("spec.json", func(s map[string]any) {
				sub(s, "tool")["executable"] = "tool"
				s["argv"] = []any{"tool"}
				s["environment"] = map[string]any{"PATH": "~/bin"}
				s["outputs"] = []any{}
			})
			w.create(spec, filepath.Join(w.root, "o.json"), "--overwrite")
		}
		delete(w.env, "HOME")
		w.create(w.editSpec("spec.json", func(s map[string]any) {
			sub(s, "tool")["executable"] = "tool"
			s["argv"] = []any{"tool"}
			s["environment"] = map[string]any{"PATH": "~/bin"}
		}), filepath.Join(w.root, "o.json"), "--overwrite")
	})
	return cs
}
