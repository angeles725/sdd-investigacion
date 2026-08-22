# Dependency and Environment Manifest

**Toolbelt root:** `research-sdd/toolbelt/`

> **Host-snapshot caveat**: every absolute path in this file is a snapshot of
> the machine where it was last verified. Paths differ on other hosts. What is
> portable is the **resolution mechanism** (env var, function branch, PATH
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

## Live Tool State

**Do not rely on any static table in this file for tool availability on a given
host.** Run the authoritative inventory:

```bash
bash research-sdd/toolbelt/detect-tools.sh
```

The script emits a 37-row capability report — covering the major RE/decompile
tools the toolbelt depends on, including PATH binaries, JVM tools, Java decompiler JARs (whose
SHA256 digests it *reports* — it does NOT compare them against the pins in
`corroborate_java.py`; that comparison is manual), Python packages,
and Hyperscan (`libhs` via `rsdd_pkg_config`) — with per-tool resolution results
and AVAILABLE / UNUSABLE / MISSING classification. It is the only trustworthy
answer for a given host at a given moment.

---

## Resolution Mechanisms

The mechanisms below are stable (they describe code, not state).

**PATH binaries** are found via `type -P` in a login bash shell. Linuxbrew
(`/home/linuxbrew/.linuxbrew/bin`) and `~/.local/bin` are on the login PATH
but may be absent in non-login shells.

**`rsdd_resolve_ghidra_home()`** (`lib/tool-env.sh:94-130`) checks **six**
branches in order: ① `ANALYZE_HEADLESS` env var (exact binary path, must
be executable with parent dir named `support`); ② `GHIDRA_HOME` env var
(must contain `support/analyzeHeadless`); ③ `GHIDRA_INSTALL_DIR` env var
(same check); ④ `analyzeHeadless` on PATH (parent dir must be named
`support`); ⑤ brew (`$brew/opt/ghidra/libexec`, checked for
`support/analyzeHeadless`); ⑥ `/opt/ghidra*` glob fallback (sorted by
version, non-Homebrew tarball installs).

**Java decompiler JARs** (`rsdd_resolve_java_jar()`, `lib/tool-env.sh`):
first checks `VINEFLOWER_JAR` / `CFR_JAR` / `PROCYON_JAR` env vars (and their
legacy aliases `VINEFLOWER` / `CFR` / `PROCYON`) — an explicitly set var is
authoritative and never falls through. If unset, searches
`$RESEARCH_SDD_TOOL_HOME/java/` (default:
`~/.local/share/research-sdd-tools/java/`); Vineflower additionally resolves
via the Homebrew `opt/vineflower` path. There are **no per-user fallback
paths** — provision the JARs into the canonical tool home with
`install-tool.sh <name>`, or set the override env var. On a host where the JAR
is at the canonical tool home, **no env var export is required**. `rsdd_probe_java_jar()` (`lib/tool-env.sh:182-194`)
validates the resolved JAR structurally (correct expected class entry, archive
integrity via `unzip`) without executing it. `corroborate-java.sh:15-24` uses
exactly this resolver + probe pair.

**`ilspycmd`** resolves via `rsdd_resolve_ilspy` in `lib/tool-env.sh`: the
`ILSPYCMD` env var (authoritative — treated as unusable if set but not
executable, never silently masked), then a PATH lookup, then the portable
`$HOME/.dotnet/tools/ilspycmd` default (the `dotnet tool install -g` location —
`$HOME`-relative, so no per-machine path is baked in). `decompile-net.sh`
locates the .NET runtime via `_rsdd_dotnet_root`: `RSDD_DOTNET_ROOT` (kit
override — fail-closed if set but unusable) → ambient `DOTNET_ROOT` (may fall
through to derivation when unusable, fixing old-runtime shadowing) → derived
from the `dotnet` binary on PATH. Each candidate is validated by running
`DOTNET_ROOT=<candidate> ilspycmd --version`; structural existence alone is not
accepted. `DOTNET_ROLL_FORWARD=Major` is still exported for resilience.
`detect-tools.sh` resolves DOTNET_ROOT via `rsdd_resolve_dotnet_root` (the same
function used by `decompile-net.sh`) before reporting availability, so the two
agree: a working ilspycmd is reported AVAILABLE in both places.

**`r2`** is resolved by `corroborate_native.py:154` via `RSDD_R2` env var
then PATH. The binary name is `r2`, not `radare2`.

**`kaitaistruct`** (Python module) is loaded via the rsdd-kaitai venv.
`RSDD_KAITAI_PY` defaults to `$HOME/.local/share/rsdd-kaitai/bin/python`
(set at `tests/kaitai.test.sh:19`).

**`frida` / `frida-trace`** are resolved via `FRIDA_BIN` / `FRIDA_TRACE_BIN`
env vars in `dynamic.sh`, defaulting to the bare command names on PATH.

**`unzip`** is resolved via `command -v unzip` in `lib/tool-env.sh:191` for
JAR archive validation inside `rsdd_probe_java_jar()`.

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

**CI result**: 71 suites, all green. RE-tool suites that depend on Ghidra,
kaitai, capa, tshark, etc. skip cleanly because their guards detect the absent
tools.

---

## Graceful Degradation

**Nearly every** RE-tool test suite opens with a tool-availability guard that
prints `SKIP: <suite> (missing: <tool>)` and exits 0 when a required binary is
absent. Many suites also fabricate fake binaries by overriding `RSDD_*` env vars
(`RSDD_BWRAP`, `RSDD_MANIFEST_CLI`, `RSDD_R2`, `RSDD_KAITAI_PY`, etc.) or
writing temporary stub scripts to a temp `PATH`.

All three previously-gapped suites now skip gracefully (issues **#78** and **#80**
merged in PR #84, commit ddf7857):

- **`decompile-native.test.sh`**: per-test guard on the quick-mode test only
  (commit da9a438, issue #85). When `file` or `strings` is absent the suite
  prints `SKIP  quick mode (missing: file or strings)` and continues; the
  other four host-independent assertions (ghidra-evidence, missing-adapter,
  raw-ghidra, r2) still run and the suite exits 0 reporting `4 passed`.
- **`jvm-callgraph.test.sh`**: two guards — Java 21 absent → suite SKIP; Java 21
  present but `mvn` absent → suite SKIP (`SKIP: jvm-callgraph tests (missing: mvn)`).
- **`tool-env.test.sh`**: test #5 now prints `SKIP  5 JAR probe is structural and
  engine-specific (unzip absent)` and skips that test (not the whole suite) when
  `unzip` is absent.

**Result on CI** (`python3 + node + bash` only): all 71 suites pass because
`file`, `strings`, and `unzip` are present on `ubuntu-latest`, and
`jvm-callgraph.test.sh` skips when Java 21 is absent from the CI runner.

---

## WSL2 Environment Note

The host runs inside Windows (kernel contains `microsoft-standard-WSL2`).
`/mnt/c` is mounted and on `PATH`, which is why `mvn` may resolve to a Windows
binary path on this machine. The `/mnt/c` bridge is **not an isolation
boundary**: Windows processes and the WSL2 filesystem share a trust context.

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
mvn (Maven 3.6+)                             # jvm-callgraph.sh build step (lines 19, 24)
Ghidra 10+ (brew or tarball)                 # Ghidra headless
vineflower/cfr/procyon JARs                  # Java decompilation
kaitai-struct-compiler + kaitaistruct venv   # Kaitai corroboration
pymupdf4llm + PyMuPDF in RESEARCH_SDD_VENV   # PDF Tier 1 extraction
pdfinfo, pdftotext, pdffonts, pdftoppm       # poppler PDF tools
tesseract, ocrmypdf (or marker/docling)      # PDF Tier 2 OCR
pandoc                                       # web-page → Markdown (fetch-doc.sh web mode)
curl (or wget)                               # document downloads (fetch-doc.sh)
ilspycmd (any version) + compatible .NET runtime  # .NET decompilation; runtime located via DOTNET_ROOT resolution in decompile-net.sh (RSDD_DOTNET_ROOT → DOTNET_ROOT → derived from dotnet binary; each probed with ilspycmd --version)
gh                                           # GitHub remote (ensure-remote.sh)
unzip                                        # JAR validation (lib/tool-env.sh)
shellcheck, bats, jq                         # dev/CI tooling
```

For unblob corroboration: `corroborate-unblob.sh` runs unblob inside a hardened
bwrap sandbox with a **minimal `/usr`-only PATH** (`/usr/bin:/usr/sbin:/bin:/sbin`),
deliberately excluding linuxbrew. unblob's external extractors must therefore
resolve under `/usr`: an extractor installed **only** under linuxbrew (e.g. `lz4`,
`zstd`) is invisible inside the sandbox, so the format it handles is not extracted
(reported as `ExtractorDependencyNotFoundReport`, exit 1). Install unblob's
extractors as distro packages so they land under `/usr` with their own libraries —
`apt install zstd lz4 squashfs-tools`, plus `sasquatch` / `jefferson` /
`ubi_reader` / erofs tools as the target formats require. Do NOT bind linuxbrew
into the sandbox: it breaks the minimal profile and pulls in the Cellar
dependency closure. Verify with `unblob --show-external-dependencies` and confirm
each reported tool resolves under `/usr`, not linuxbrew.

For Java decompiler JARs: `rsdd_resolve_java_jar()` checks env var overrides
FIRST (authoritative — an invalid override fails hard, it never falls through),
then `$RESEARCH_SDD_TOOL_HOME/java/` (default:
`~/.local/share/research-sdd-tools/java/`); Vineflower additionally resolves via
the Homebrew `opt` path. There are no per-user fallback paths. Provision the
JARs into the tool_home path with `install-tool.sh <name>` and no env var
export is required. SHA256 pins are recorded in
`corroborate_java.py` (`DEFAULT_PINS`); use those to verify the correct
versions.
