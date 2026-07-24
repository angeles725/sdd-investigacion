# Dependency and Environment Manifest

**Toolbelt root:** `research-sdd/toolbelt/`  
**Verified:** 2026-07-24 · WSL2 kernel `5.15.167.4-microsoft-standard-WSL2`  
**Python:** 3.14.6 · **Node:** 22.22.2

> **Host-snapshot caveat**: every absolute path in this file is a snapshot of
> the machine where this was verified. Paths will differ on other hosts. What
> is portable is the **resolution mechanism** (env var, function branch, PATH
> lookup), not the path itself.

---

## Python

All `*.py` source files use **stdlib only** — `argparse`, `ctypes`, `datetime`,
`fcntl`, `hashlib`, `importlib`, `json`, `mmap`, `os`, `pathlib`, `platform`,
`posixpath`, `re`, `resource`, `select`, `shlex`, `signal`, `stat`, `struct`,
`subprocess`, `sys`, `threading`, `time`, `typing`, `zipfile`, `urllib`,
`unicodedata`, and similar. No `*.py` file imports a third-party package.

**One exception in a shell script**: `extract-pdf.sh` embeds Python via a
heredoc (lines 98-123) and imports `pymupdf4llm` and `fitz` (PyMuPDF). This
block is run through `$RESEARCH_SDD_VENV/bin/python` — a separate project
venv — never through system Python. Two third-party packages are therefore
required; both are declared in `requirements.txt`.

Internal modules (`adapter_core`, `gate`, `vm_*`, `docker_*`, `proc_common`,
`squashfs_extract`, `corroborate_*`, etc.) are local files within this tree —
not packages to install.

## Node

**Zero npm dependencies.** The two `.test.mjs` suites use only `node:` builtins
and the local `.mjs` SUTs. No `package.json`, no `node_modules`.

---

## External Tool Inventory

Tools land in one of four states:

- **wired** — binary/JAR found at its resolved path, works without extra configuration
- **present-not-wired** — artifact exists on disk but requires an env-var export to activate
- **absent** — not present on this host
- **probe-only** — detected by `detect-tools.sh` but not invoked by any production script

**Resolution mechanisms:**

- **PATH binaries** are found via `type -P` in a login bash shell. Linuxbrew
  (`/home/linuxbrew/.linuxbrew/bin`) and `~/.local/bin` are on the login PATH
  but may be absent in non-login shells.

- **`rsdd_resolve_ghidra_home()`** (`lib/tool-env.sh:94-130`) checks five
  branches in order: ① `ANALYZE_HEADLESS` env var (exact binary path, must
  be executable with parent dir named `support`); ② `GHIDRA_HOME` env var
  (must contain `support/analyzeHeadless`); ③ `GHIDRA_INSTALL_DIR` env var
  (same check); ④ `analyzeHeadless` on PATH (parent dir must be named
  `support`); ⑤ brew (`$brew/opt/ghidra/libexec`, checked for
  `support/analyzeHeadless`); ⑥ `/opt/ghidra*` glob fallback (sorted by
  version, non-Homebrew tarball installs). On this host the brew branch (⑤)
  fires; all env-var overrides are unset.

- **Java decompiler JARs** are passed via `VINEFLOWER_JAR` / `CFR_JAR` /
  `PROCYON_JAR` (or the legacy `VINEFLOWER` / `CFR` / `PROCYON` names);
  `rsdd_resolve_java_jar()` also searches `RESEARCH_SDD_TOOL_HOME/java/` and
  a few well-known local paths as fallback.

- **`ilspycmd`** resolves via `ILSPYCMD` env var, falling back to
  `~/.dotnet/tools/ilspycmd`. `decompile-net.sh` exports
  `DOTNET_ROLL_FORWARD=Major` so ilspycmd (targeting net6.0) rolls forward to
  the installed .NET 8 runtime. `detect-tools.sh`'s smoke test omits that env
  var and therefore reports UNUSABLE — the tool is functional via the script.

- **`r2`** is resolved by `corroborate_native.py:154` via `RSDD_R2` env var
  then PATH. The binary name is `r2`, not `radare2`.

- **`kaitaistruct`** (Python module) is loaded via the rsdd-kaitai venv.
  `RSDD_KAITAI_PY` defaults to `$HOME/.local/share/rsdd-kaitai/bin/python`
  (set at `tests/kaitai.test.sh:19`).

- **`frida` / `frida-trace`** are resolved via `FRIDA_BIN` / `FRIDA_TRACE_BIN`
  env vars in `dynamic.sh`, defaulting to the bare command names on PATH.

- **`unzip`** is resolved via `command -v unzip` in `lib/tool-env.sh:191` for
  JAR archive validation inside `rsdd_probe_java_jar()`.

### Wired and Available

| Tool | Resolved path | Invoked by |
|------|--------------|------------|
| `analyzeHeadless` (Ghidra) | `/home/linuxbrew/.linuxbrew/opt/ghidra/libexec/support/analyzeHeadless` | `decompile-native.sh`, `corroborate-ghidra.sh`; resolved via `rsdd_resolve_ghidra_home()` brew branch |
| `bwrap` | `/usr/bin/bwrap` | All sandbox adapters (effectively required); must be root-owned and non-group/other-writable |
| `qemu-system-x86_64` | `/usr/bin/qemu-system-x86_64` | VM detonation (x86\_64); resolved by `qemu_plan.py` as `qemu-system-{arch}` |
| `qemu-system-arm` | `/usr/bin/qemu-system-arm` | VM detonation (ARM); same dynamic resolution |
| `docker` | `/usr/bin/docker` | Container-based dynamic analysis |
| `tshark` | `/usr/bin/tshark` | PCAP dissection (`corroborate_pcap.py`) |
| `capinfos` | `/usr/bin/capinfos` | PCAP metadata (`corroborate_pcap.py` via `RSDD_CAPINFOS`) |
| `dumpcap` | `/usr/bin/dumpcap` | Live packet capture (`lib/capture_exec.py`) |
| `binwalk` | `/usr/bin/binwalk` | Firmware scanning (`scan-firmware.sh`, `corroborate_firmware.py`); **must be exactly `/usr/bin/binwalk`, root-owned, and not group/other-writable** (`corroborate_firmware.py:197-198`) |
| `unblob` | `/home/cristian/.local/bin/unblob` | Firmware extraction (`corroborate-unblob.sh`) |
| `unsquashfs` | `/usr/bin/unsquashfs` | SquashFS extraction |
| `r2` | `/home/linuxbrew/.linuxbrew/bin/r2` | Native binary RE (`corroborate_native.py` via `RSDD_R2` then PATH) |
| `objdump` | `/usr/bin/objdump` | Native binary RE |
| `readelf` | `/usr/bin/readelf` | Native binary RE |
| `file` | `/usr/bin/file` | `decompile-native.sh:25` (unguarded in `quick` mode); `fetch-doc.sh:63` |
| `strings` | `/usr/bin/strings` | `decompile-native.sh:27` (unguarded in `quick` mode) |
| `yara` | `/home/linuxbrew/.linuxbrew/bin/yara` | `scan-firmware.sh:32` (guarded: exits 3 if absent) |
| `floss` | `/home/cristian/.local/bin/floss` | String extraction RE |
| `capa` | `/home/cristian/.local/bin/capa` | Capability RE (rules dir also required) |
| `java` | `/home/linuxbrew/.linuxbrew/opt/openjdk@21/bin/java` | JVM execution; resolved by `rsdd_resolve_java_home()` |
| `javap` | `/home/linuxbrew/.linuxbrew/opt/openjdk@21/bin/javap` | JVM bytecode inspection |
| `jdeps` | `/home/linuxbrew/.linuxbrew/opt/openjdk@21/bin/jdeps` | JVM dependency analysis (`corroborate_java.py`) |
| `kaitai-struct-compiler` | `/home/linuxbrew/.linuxbrew/bin/kaitai-struct-compiler` | Kaitai schema compilation |
| `kaitaistruct` (Python module) | `/home/cristian/.local/share/rsdd-kaitai/bin/python` (rsdd-kaitai venv) | Kaitai corroboration (`lib/kaitai_driver.py`); default of `RSDD_KAITAI_PY`; `import kaitaistruct` → 0.11 ✓; tests: 19/19 |
| `mvn` | `/mnt/c/apache-maven/apache-maven-3.9.11/bin/mvn` | Maven builds (Windows binary via `/mnt/c`) |
| `pdftotext` | `/home/linuxbrew/.linuxbrew/bin/pdftotext` | PDF text extraction |
| `pdfinfo` | `/home/linuxbrew/.linuxbrew/bin/pdfinfo` | PDF metadata; **required** by `extract-pdf.sh:63` (`die` if absent) |
| `pdffonts` | `/home/linuxbrew/.linuxbrew/bin/pdffonts` | `extract-pdf.sh:89` (guarded: `have pdffonts &&`; skipped if absent) |
| `pdftoppm` | `/home/linuxbrew/.linuxbrew/bin/pdftoppm` | `extract-pdf.sh` Tier 2 tesseract path; `fetch-doc.sh:53` (ocr mode) |
| `tesseract` | `/home/linuxbrew/.linuxbrew/bin/tesseract` | `extract-pdf.sh` Tier 2 OCR; `fetch-doc.sh:51` (guarded: exits 3 if absent) |
| `pandoc` | `/home/linuxbrew/.linuxbrew/bin/pandoc` | `fetch-doc.sh:75` web mode (guarded: falls back to `cp` if absent) |
| `curl` | `/home/linuxbrew/.linuxbrew/bin/curl` | `fetch-doc.sh:60,74` (primary downloader; `wget` is fallback) |
| `wget` | `/usr/bin/wget` | `fetch-doc.sh:60,74` (fallback when `curl` fails) |
| `pymupdf4llm` + `fitz` (PyMuPDF) | `~/.local/share/research-sdd-tools/venv/bin/python` (RESEARCH\_SDD\_VENV) | `extract-pdf.sh` Tier 1 heredoc; `pymupdf4llm` 1.28.0 + `PyMuPDF` 1.28.0 installed; detected by `detect-tools.sh` via `import pymupdf4llm` probe |
| `ocrmypdf` | `/home/cristian/.local/share/research-sdd-tools/venv/bin/ocrmypdf` | `extract-pdf.sh:39` Tier 2 default (venv then PATH) |
| `marker_single` | `/home/cristian/.local/share/research-sdd-tools/venv/bin/marker_single` | `extract-pdf.sh:40` Tier 2 premium (venv then PATH) |
| `docling` | `/home/cristian/.local/share/research-sdd-tools/venv/bin/docling` | `extract-pdf.sh:41` Tier 2 premium (venv then PATH) |
| `ilspycmd` | `/home/cristian/.dotnet/tools/ilspycmd` | .NET decompilation (`decompile-net.sh`); requires `DOTNET_ROLL_FORWARD=Major` (set by the script); `detect-tools.sh` reports UNUSABLE because its smoke test omits that env var |
| `gh` | `/usr/bin/gh` | `ensure-remote.sh:69` (guarded: exits 7 if absent) |
| `unzip` | `/home/linuxbrew/.linuxbrew/bin/unzip` | `lib/tool-env.sh:191` JAR archive validation inside `rsdd_probe_java_jar()` |
| `bash` | `/usr/bin/bash` | CI / all shell scripts |
| `jq` | `/home/linuxbrew/.linuxbrew/bin/jq` | CI / JSON processing |
| `git` | `/home/linuxbrew/.linuxbrew/bin/git` | CI / version control |
| `shellcheck` | `/home/linuxbrew/.linuxbrew/bin/shellcheck` | CI / shell linting |
| `bats` | `/home/linuxbrew/.linuxbrew/bin/bats` | CI / test runner |

### Present but NOT Wired

These JARs exist on disk with SHA256 hashes that match `DEFAULT_PINS` in
`corroborate_java.py` exactly. The env vars are unset. **No download needed —
only export:**

| JAR | Path | SHA256 (first 8 chars; full verified) | Wire with |
|-----|------|---------------------------------------|-----------|
| vineflower | `/home/cristian/modules/Prototipos/Reflow/vineflower.jar` | `a615d07d…` ✓ | `VINEFLOWER_JAR=<path>` |
| cfr | `/home/cristian/modules/Prototipos/Reflow/cfr.jar` | `f686e8f3…` ✓ | `CFR_JAR=<path>` |
| procyon | `/home/cristian/modules/Prototipos/modulos/procyon.jar` | `821da960…` ✓ | `PROCYON_JAR=<path>` |

Also export `JAVA_HOME` pointing to the JDK to complete the corroboration path.

### Genuinely Absent

| Tool | Invoked by | How to obtain |
|------|-----------|---------------|
| `frida` | `dynamic.sh` via `FRIDA_BIN` (defaults to `frida` on PATH) | `pipx install frida-tools` or `install-tool.sh frida` |
| `frida-trace` | `dynamic.sh` via `FRIDA_TRACE_BIN` (defaults to `frida-trace` on PATH) | ships with frida-tools |
| `jadx` | `detect-tools.sh` probe only; no corroboration adapter invokes it directly | `brew install jadx` |

### Probe-only in `detect-tools.sh`

These tools are detected and reported by `detect-tools.sh` but are **not
invoked by any production toolbelt script**. They are listed here for
completeness and to map the full `detect-tools.sh` capability report to this
inventory.

| Tool | Path on this host | Status |
|------|-------------------|--------|
| `nm` | `/usr/bin/nm` | AVAILABLE |
| `tcpdump` | `/usr/bin/tcpdump` | AVAILABLE |
| `gdb` | `/usr/bin/gdb` | AVAILABLE |
| `gdb-multiarch` | `/usr/bin/gdb-multiarch` | AVAILABLE |
| `strace` | `/usr/bin/strace` | AVAILABLE |
| `ltrace` | `/usr/bin/ltrace` | AVAILABLE |
| `qemu-arm-static` | `/usr/bin/qemu-arm-static` | AVAILABLE |
| `qemu-img` | `/usr/bin/qemu-img` | AVAILABLE |
| `apktool` | — | MISSING |
| `pycdc` | — | MISSING (checked at `~/dev/pycdc/pycdc`) |

---

## What CI Actually Installs

`.github/workflows/toolbelt-tests.yml` defines two jobs running on
`ubuntu-latest`:

**Job 1 — `toolbelt-tests`** (10 min timeout):
1. Check out repo
2. Set up Node.js 20 (via `setup-node`)
3. Sanity-check `python3 --version` (`python3`, `bash`, `git` are preinstalled)
4. Run `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth`
5. Run `bash research-sdd/install/tests/research-sdd-install.test.sh --prove-teeth`

**Job 2 — `shellcheck`** (5 min timeout):
1. Check out repo
2. Run `shellcheck -S warning` across all `*.sh` files in `research-sdd/toolbelt/` and `research-sdd/install/`

No RE tools, no VM stack, no Java, no PCAP, no Ghidra are installed in CI.
Effective CI minimum: `python3 + node + bash`. Heavy-RE suites skip gracefully;
`shellcheck` gates coding-style compliance independently.

---

## Graceful Degradation

**Nearly every** RE-tool test suite opens with a tool-availability guard that
prints `SKIP: <suite> (missing: <tool>)` and exits 0 when a required binary is
absent. For example, `kaitai.test.sh` has **two** guards (lines 20-31 of the
actual source; the first code block in an earlier version of this file dropped
the second):

```bash
_KAITAI_PY="${RSDD_KAITAI_PY:-$HOME/.local/share/rsdd-kaitai/bin/python}"
for _cmd in bwrap python3 kaitai-struct-compiler; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: kaitai tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done
if ! [ -x "$_KAITAI_PY" ]; then
  echo "SKIP: kaitai tests (kaitai venv python absent: $_KAITAI_PY)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi
```

Many suites also fabricate fake binaries by overriding `RSDD_*` env vars
(`RSDD_BWRAP`, `RSDD_MANIFEST_CLI`, `RSDD_R2`, `RSDD_KAITAI_PY`, etc.) or
writing temporary stub scripts to a temp `PATH`.

**Known exception — `decompile-native.test.sh`**: `decompile-native.sh`
calls `file` (line 25) and `strings` (line 27) unguarded in `quick` mode. If
either binary is absent, `decompile-native.test.sh` **fails** (it does not
skip). Tracked as issue **#78**. Do not make the unqualified "all suites skip
gracefully" claim until #78 is resolved.

**Result on CI** (`python3 + node + bash` only): all 71 suites pass, all
1 339 test cases pass, because `decompile-native.test.sh` uses the real `file`
and `strings` (present on `ubuntu-latest`). Absent-tool suites for Ghidra,
kaitai, capa, tshark, etc. skip cleanly.

---

## WSL2 Environment Note

The host runs inside Windows (kernel contains `microsoft-standard-WSL2`).
`/mnt/c` is mounted and on `PATH`, which is why `mvn` resolves to a Windows
binary path. The `/mnt/c` bridge is **not an isolation boundary**: Windows
processes and the WSL2 filesystem share a trust context.

This is the principal reason untrusted firmware samples are detonated inside a
disposable QEMU VM, never on the host directly. The `bwrap` sandbox is a
belt-and-suspenders measure for analysis tooling, not a substitute for VM
isolation.

---

## Fresh Machine: Minimum vs. Full Surface

**To run the test suite:**
```
python3 (3.9+), node (18+), bash (4+)
```

**To unlock the full RE capability surface (in addition to the above):**
```
bwrap, qemu-system-x86_64/arm, docker        # VM + sandbox
tshark, capinfos, dumpcap                    # PCAP
binwalk (must be /usr/bin/binwalk, root-owned, non-group/other-writable)
unblob, unsquashfs                           # firmware extraction
r2, objdump, readelf, file, strings          # native RE
floss, capa + rules dir                      # string/capability RE
yara                                         # signature scanning
JDK 21+                                      # JVM tools (java, javap, jdeps)
Ghidra 10+ (brew or tarball)                # Ghidra headless
vineflower/cfr/procyon JARs + env vars       # Java decompilation
kaitai-struct-compiler + kaitaistruct venv   # Kaitai corroboration
pymupdf4llm + PyMuPDF in RESEARCH_SDD_VENV   # PDF Tier 1 extraction
pdfinfo, pdftotext, pdffonts, pdftoppm       # poppler PDF tools
tesseract, ocrmypdf (or marker/docling)      # PDF Tier 2 OCR
pandoc                                       # web-page → Markdown (fetch-doc.sh web mode)
curl (or wget)                               # document downloads (fetch-doc.sh)
ilspycmd + .NET 8 runtime + DOTNET_ROLL_FORWARD=Major  # .NET decompilation
gh                                           # GitHub remote (ensure-remote.sh)
unzip                                        # JAR validation (lib/tool-env.sh)
shellcheck, bats, jq                         # dev/CI tooling
```

For Java decompiler JARs: the toolbelt pins SHA256 hashes in `corroborate_java.py`
(`DEFAULT_PINS`). The JARs on this host already match those pins; a fresh
machine must download matching versions and export the three `RSDD_CORROBORATE_*`
variables (or `VINEFLOWER_JAR` / `CFR_JAR` / `PROCYON_JAR`).
