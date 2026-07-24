# Dependency and Environment Manifest

**Toolbelt root:** `research-sdd/toolbelt/`  
**Verified:** 2026-07-24 · WSL2 kernel `5.15.167.4-microsoft-standard-WSL2`  
**Python:** 3.14.6 · **Node:** 22.22.2

---

## Python

The toolbelt is **stdlib-only** for all core operations. The single external
PyPI package (`kaitaistruct`) is optional. See `requirements.txt` for the
pinned declaration and installation instructions.

Internal modules (`adapter_core`, `gate`, `vm_*`, `docker_*`, `proc_common`,
`squashfs_extract`, `corroborate_*`, etc.) are local files within this tree —
not packages to install.

## Node

**Zero npm dependencies.** The two `.test.mjs` suites use only `node:` builtins
and the local `.mjs` SUTs. No `package.json`, no `node_modules`.

---

## External Tool Inventory

Tools land in one of three states:  
- **wired** — binary/JAR found at its resolved path with no extra configuration  
- **present-not-wired** — artifact exists on disk but requires an env-var export  
- **absent** — not present on this host

**Resolution mechanisms:** PATH binaries are found via `type -P` in a login
shell. Ghidra is resolved by `rsdd_resolve_ghidra_home()` in `lib/tool-env.sh`
(checks `ANALYZE_HEADLESS`, `GHIDRA_HOME`, `GHIDRA_INSTALL_DIR`, then
`analyzeHeadless` on PATH, then brew, then `/opt/ghidra*`). Java decompiler
JARs are passed via `RSDD_CORROBORATE_{VINEFLOWER,CFR,PROCYON}`. `ilspycmd`
resolves via `ILSPYCMD` env var falling back to `~/.dotnet/tools/ilspycmd`.

### Wired and Available

| Tool | Resolved path | Gates |
|------|--------------|-------|
| `bwrap` | `/usr/bin/bwrap` | All sandbox adapters (effectively required) |
| `qemu-system-x86_64` | `/usr/bin/qemu-system-x86_64` | VM detonation (x86\_64) |
| `qemu-system-arm` | `/usr/bin/qemu-system-arm` | VM detonation (ARM) |
| `docker` | `/usr/bin/docker` | Container-based dynamic analysis |
| `tshark` | `/usr/bin/tshark` | PCAP dissection |
| `capinfos` | `/usr/bin/capinfos` | PCAP metadata |
| `dumpcap` | `/usr/bin/dumpcap` | Live packet capture |
| `binwalk` | `/usr/bin/binwalk` | Firmware scanning |
| `unblob` | `/home/cristian/.local/bin/unblob` | Firmware extraction |
| `unsquashfs` | `/usr/bin/unsquashfs` | SquashFS extraction |
| `radare2` / `r2` | `/home/linuxbrew/.linuxbrew/bin/radare2` | Native binary RE |
| `objdump` | `/usr/bin/objdump` | Native binary RE |
| `readelf` | `/usr/bin/readelf` | Native binary RE |
| `floss` | `/home/cristian/.local/bin/floss` | String extraction RE |
| `capa` | `/home/cristian/.local/bin/capa` | Capability RE (rules dir also required) |
| `java` | `/home/linuxbrew/.linuxbrew/bin/java` | JVM execution |
| `javap` | `/home/linuxbrew/.linuxbrew/bin/javap` | JVM bytecode inspection |
| `jdeps` | `/home/linuxbrew/.linuxbrew/bin/jdeps` | JVM dependency analysis |
| `kaitai-struct-compiler` | `/home/linuxbrew/.linuxbrew/bin/kaitai-struct-compiler` | Kaitai schema compilation |
| `mvn` | `/mnt/c/apache-maven/apache-maven-3.9.11/bin/mvn` | Maven builds (Windows binary via `/mnt/c`) |
| `pdftotext` | `/home/linuxbrew/.linuxbrew/bin/pdftotext` | PDF text extraction |
| `pdfinfo` | `/home/linuxbrew/.linuxbrew/bin/pdfinfo` | PDF metadata |
| `mutool` | `/usr/bin/mutool` | PDF processing |
| `qpdf` | `/home/linuxbrew/.linuxbrew/bin/qpdf` | PDF/ZIP manipulation |
| `ilspycmd` | `/home/cristian/.dotnet/tools/ilspycmd` | .NET decompilation (default path wired) |
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
| vineflower | `/home/cristian/modules/Prototipos/Reflow/vineflower.jar` | `a615d07d…` ✓ | `RSDD_CORROBORATE_VINEFLOWER=<path>` |
| cfr | `/home/cristian/modules/Prototipos/Reflow/cfr.jar` | `f686e8f3…` ✓ | `RSDD_CORROBORATE_CFR=<path>` |
| procyon | `/home/cristian/modules/Prototipos/modulos/procyon.jar` | `821da960…` ✓ | `RSDD_CORROBORATE_PROCYON=<path>` |

Also export `JAVA_HOME` pointing to the JDK to complete the corroboration path.

### Genuinely Absent

| Tool | Gates | How to obtain |
|------|-------|---------------|
| `analyzeHeadless` (Ghidra) | Ghidra headless static analysis | Download a Ghidra release; set `GHIDRA_HOME` |
| `jadx` | Java decompilation (detect-tools probe only; no corroboration adapter invokes it directly) | `brew install jadx` |
| `kaitaistruct` (Python module) | Kaitai corroboration path | Create rsdd-kaitai venv; `pip install kaitaistruct` (see `requirements.txt`) |

`sasquatch` is not referenced in any toolbelt script; `unsquashfs` is used instead.

---

## What CI Actually Installs

`.github/workflows/toolbelt-tests.yml` runs on `ubuntu-latest`. It installs
Node 20 (via `setup-node`); `python3`, `bash`, `git`, `shellcheck` are
preinstalled. **Nothing else** — no RE tools, no VM stack, no Java, no PCAP.
Heavy-RE suites take the SKIP or stub path. Effective CI minimum: `python3 + node + bash`.

---

## Graceful Degradation

Every RE-tool test suite opens with a tool-availability guard that prints
`SKIP: <suite> (missing: <tool>)` and exits 0 when a required binary is absent.
Example from `kaitai.test.sh`:

```bash
for _cmd in bwrap python3 kaitai-struct-compiler; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "SKIP: kaitai tests (missing: $_cmd)"; exit 0; }
done
```

Many suites also fabricate fake binaries by overriding `RSDD_*` env vars
(`RSDD_BWRAP`, `RSDD_MANIFEST_CLI`, `RSDD_R2`, `RSDD_KAITAI_PY`, etc.) or
writing temporary stub scripts to a temp `PATH`.

**Result:** `python3 + node + bash` is sufficient to run the full test suite
without any failures — absent-tool tests are skipped, not failed.

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
binwalk, unblob, unsquashfs                  # firmware
radare2, objdump, readelf                    # native RE
floss, capa + rules dir                      # string/capability RE
JDK 11+, Ghidra 10+                         # JVM / Ghidra headless
vineflower/cfr/procyon JARs + env vars       # Java decompilation
kaitai-struct-compiler + kaitaistruct venv   # Kaitai corroboration
pdftotext, pdfinfo, mutool, qpdf             # PDF extraction
shellcheck, bats, jq                         # dev/CI tooling
```

For Java decompiler JARs: the toolbelt pins SHA256 hashes in `corroborate_java.py`
(`DEFAULT_PINS`). The JARs on this host already match those pins; a fresh
machine must download matching versions and export the three `RSDD_CORROBORATE_*`
variables.
