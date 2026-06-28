#!/usr/bin/env python3
"""Autogenera CATALOG.md escaneando los bloques sdd-mental-model-bloque*.md.

Patrón espejo de niagara-research/tools/gen-catalog.py: extrae el número de
bloque del nombre de archivo y el título de la primera línea `# Bloque N — ...`.
NO editar CATALOG.md a mano; regenerar con:  python3 tools/gen-catalog.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BLOCK_RE = re.compile(r"^sdd-mental-model-bloque(\d+)\.md$")
TITLE_RE = re.compile(r"^#\s*Bloque\s*\d+\s*[—-]\s*(.+?)\s*$")


def block_title(path: Path) -> str:
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("# "):
                m = TITLE_RE.match(line)
                return m.group(1) if m else line[2:].strip()
    return "(sin título)"


def main() -> int:
    blocks: list[tuple[int, str, str]] = []
    for path in ROOT.glob("sdd-mental-model-bloque*.md"):
        m = BLOCK_RE.match(path.name)
        if not m:
            continue
        blocks.append((int(m.group(1)), path.name, block_title(path)))

    blocks.sort(key=lambda b: b[0])

    lines = [
        "<!-- AUTOGENERADO por tools/gen-catalog.py — NO EDITAR A MANO. "
        "Regenerar: python3 tools/gen-catalog.py -->",
        "",
        "# Catálogo de bloques — SDD de gentle-ai",
        "",
        f"Total: **{len(blocks)} bloques**",
        "",
        "| Bloque | Archivo | Título |",
        "|--------|---------|--------|",
    ]
    for num, fname, title in blocks:
        lines.append(f"| {num} | [{fname}]({fname}) | {title} |")
    lines.append("")

    out = ROOT / "CATALOG.md"
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"CATALOG.md regenerado: {len(blocks)} bloques.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
