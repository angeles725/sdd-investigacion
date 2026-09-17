# sdd-investigacion

Research-SDD kit — toolbelt, methodology, and loop infrastructure for structured
reverse-engineering and document-mode research using the SDD workflow.

## Quickstart (WSL2 Ubuntu)

```bash
git clone https://github.com/angeles725/sdd-investigacion.git ~/investigacion/sdd-investigacion
cd ~/investigacion/sdd-investigacion

# Install BASELINE deps + wire the kit skill into your AI harness.
bash research-sdd/install/install.sh

# Optional: add heavy analysis tiers in one step.
bash research-sdd/install/install.sh --with-binary --with-pdf --with-net

# Reload your shell after install.
source ~/.bashrc
```

The installer is idempotent — safe to re-run. Heavy tiers can be added later:

| Flag              | Tools installed                                              |
|-------------------|--------------------------------------------------------------|
| `--with-binary`   | binutils, radare2, openjdk-21-jdk, Vineflower/CFR/Procyon    |
| `--with-pcap`     | tshark, tcpdump, wireshark-common                            |
| `--with-firmware` | binwalk, squashfs-tools, yara, unblob                        |
| `--with-vm`       | qemu-system, qemu-user-static, qemu-utils                    |
| `--with-pdf`      | poppler-utils, tesseract-ocr, pandoc, pymupdf4llm            |
| `--with-net`      | gdb, gdb-multiarch, strace, ltrace, frida                    |
| `--with-dotnet`   | dotnet-sdk-8.0, ilspycmd, powershell                         |
| `--with-latex`    | texlive-latex-base, texlive-pictures, latexmk                |
| `--all-heavy`     | all of the above                                             |

Use `--dry-run` to preview the full plan without making any changes.

## Kit layout

```
research-sdd/
  install/          — installers (install.sh, research-sdd-install.sh)
  toolbelt/         — analysis scripts, detect-tools.sh, install-tool.sh
  METHODOLOGY.md    — research-loop doctrine
  PROMPT-LOOP.md    — loop execution guide
TARGETS.md          — registered research targets
```

## Contributing

See `CONTRIBUTING.md` for the issue-first workflow, branch naming, and quality gates.
