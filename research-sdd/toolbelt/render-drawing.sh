#!/usr/bin/env bash
# render-drawing.sh — visual oracle for DXF/DWG engineering drawings.
# Renders via ezdxf's official addons.drawing renderer: real ACI layer colours,
# lineweights, linetypes, hatches, and text — the image AutoCAD draws, not a
# hand-rolled approximation. DWG inputs are transparently pre-converted to DXF
# via dwg2dxf (LibreDWG) when present.
#
# Usage:
#   render-drawing.sh <drawing.dxf|.dwg> <out.png|.svg>
#       [--dpi N] [--style dark|light|white]
#       [--region xmin,xmax,ymin,ymax]
#       [--only LAYER [LAYER ...]] [--hide LAYER [LAYER ...]]
#   render-drawing.sh <drawing.dxf|.dwg> --list-layers
#
# Exit codes: 0 success · 2 bad-args · 3 dependency-missing · 4 render-failed
#
# READ-ONLY: never writes to the source drawing.
set -euo pipefail

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  echo "usage: render-drawing.sh <file.dxf|.dwg> <out.png|.svg> [opts]" >&2
  echo "       render-drawing.sh <file.dxf|.dwg> --list-layers" >&2
  echo "       opts: --dpi N  --style dark|light|white" >&2
  echo "             --region xmin,xmax,ymin,ymax" >&2
  echo "             --only LAYER [LAYER...]  --hide LAYER [LAYER...]" >&2
  exit 2
fi
shift

if [ ! -f "$INPUT" ]; then
  echo "render-drawing: not a file: $INPUT" >&2
  exit 2  # RD-FILE-CHECK
fi

# Dependency checks.
command -v python3 >/dev/null 2>&1 || { echo "render-drawing: python3 not found" >&2; exit 3; }
python3 -c 'import ezdxf' 2>/dev/null || { echo "render-drawing: ezdxf not installed (pip install ezdxf)" >&2; exit 3; }  # RD-EZDXF-DEP-CHECK
python3 -c 'import matplotlib' 2>/dev/null || { echo "render-drawing: matplotlib not installed (pip install matplotlib)" >&2; exit 3; }  # RD-MATPLOT-DEP-CHECK

# DWG → DXF conversion when needed.
dxf_input="$INPUT"
_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

case "$INPUT" in
  *.dwg|*.DWG)
    command -v dwg2dxf >/dev/null 2>&1 || {  # RD-DWG-DEP-CHECK
      echo "render-drawing: dwg2dxf (LibreDWG) not installed — required for .dwg input" >&2
      exit 3
    }
    dwg2dxf "$INPUT" -o "$_tmpdir/converted.dxf" >/dev/null 2>&1 || {
      echo "render-drawing: dwg2dxf conversion failed for: $INPUT" >&2
      exit 4
    }
    dxf_input="$_tmpdir/converted.dxf"
    ;;
esac

# Write the embedded Python renderer to a temp file, then execute it.
# Python exit 0 → success; Python exit 2 → bad args; Python exit 1 / other → render failed.
_pyscript="$_tmpdir/render.py"
cat > "$_pyscript" << 'PYEOF'
#!/usr/bin/env python3
"""render-drawing.sh embedded renderer.

Generic DXF visual oracle: loads any DXF file and renders it using
ezdxf's official addons.drawing backend (faithful colour, lineweight,
linetype, hatch, and text). Named regions are NOT hard-coded; pass
--region xmin,xmax,ymin,ymax for a clip.

Dangling INSERTs (block references whose definition the DXF lacks, a
common LibreDWG conversion artefact) are skipped and counted — a
missing entity is reported, never silently dropped.
"""
import argparse
import collections
import sys

import ezdxf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from ezdxf.addons.drawing import Frontend, RenderContext
from ezdxf.addons.drawing.config import Configuration, LineweightPolicy
from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
from ezdxf.addons.drawing.properties import LayoutProperties

STYLES = {
    # AutoCAD model-space look: light geometry on a near-black field.
    "dark":  {"bg": "#1a1a1a", "fg": None},
    # Plotted-on-paper look: dark geometry on a paper tone.
    "light": {"bg": "#f4f1ea", "fg": "#1c2431"},
    # Clean white background.
    "white": {"bg": "#ffffff", "fg": None},
}


def parse_args():
    p = argparse.ArgumentParser(prog="render-drawing.sh",
                                description="Render a DXF/DWG as AutoCAD draws it.")
    p.add_argument("dxf",  help="DXF file path (already converted from DWG if needed)")
    p.add_argument("out",  nargs="?", help="output PNG or SVG path")
    p.add_argument("--dpi",   type=int, default=150, help="output resolution (default 150)")
    p.add_argument("--style", default="dark", choices=list(STYLES),
                   help="colour scheme: dark (default), light, or white")
    p.add_argument("--region", default=None,
                   help="clip to 'xmin,xmax,ymin,ymax' in drawing units")
    p.add_argument("--only", nargs="*", default=None,
                   help="render only these layers")
    p.add_argument("--hide", nargs="*", default=None,
                   help="hide these layers")
    p.add_argument("--size", type=float, nargs=2, default=(16.0, 20.0),
                   metavar=("W", "H"), help="figure size in inches (default 16x20)")
    p.add_argument("--list-layers", action="store_true",
                   help="print the layer table and exit (no output file needed)")
    return p.parse_args()


def resolve_region(spec):
    if spec is None:
        return None
    try:
        v = [float(x) for x in spec.replace(" ", "").split(",")]
        if len(v) == 4:
            return tuple(v)
    except ValueError:
        pass
    sys.exit(f"render-drawing: bad --region {spec!r}; want 'xmin,xmax,ymin,ymax'")


def main():
    a = parse_args()

    try:
        doc = ezdxf.readfile(a.dxf)
    except Exception as exc:
        print(f"render-drawing: failed to read DXF: {exc}", file=sys.stderr)
        sys.exit(1)

    msp = doc.modelspace()

    if a.list_layers:
        used = collections.Counter(e.dxf.layer for e in msp)
        print(f"{'entities':>9}  {'layer':32s}  state")
        for lay in sorted(doc.layers, key=lambda lyr: lyr.dxf.name):
            n = used.get(lay.dxf.name, 0)
            state = ",".join(
                (["off"] if lay.is_off() else []) +
                (["frozen"] if lay.is_frozen() else [])
            )
            print(f"{n:9d}  {lay.dxf.name:32s}  {state}")
        return 0

    if not a.out:
        print("render-drawing: output path required (or pass --list-layers)",
              file=sys.stderr)
        sys.exit(2)

    region = resolve_region(a.region)
    only   = set(a.only) if a.only else None
    hide   = set(a.hide) if a.hide else set()

    # Dangling INSERT detection — block refs without definitions are skipped
    # and counted; a silently incomplete picture is the worst oracle failure.
    dangling = {"count": 0, "names": set()}
    block_names = {b.name for b in doc.blocks}

    def keep(e):
        lay = e.dxf.layer
        if only is not None and lay not in only:
            return False
        if lay in hide:
            return False
        if e.dxftype() == "INSERT":
            name = e.dxf.name
            if name not in block_names:
                dangling["count"] += 1
                dangling["names"].add(name)
                return False
        return True

    style = STYLES[a.style]
    fig = plt.figure(figsize=a.size, dpi=a.dpi)
    ax = fig.add_axes([0.02, 0.02, 0.96, 0.95])

    try:
        cfg = Configuration(
            lineweight_scaling=1.0,
            lineweight_policy=LineweightPolicy.RELATIVE,
        )
        ctx = RenderContext(doc)
        backend = MatplotlibBackend(ax)
        layout_props = LayoutProperties.from_layout(msp)
        layout_props.set_colors(style["bg"], style["fg"])
        Frontend(ctx, backend, config=cfg).draw_layout(
            msp, finalize=False, filter_func=keep,
            layout_properties=layout_props)
    except Exception as exc:
        plt.close(fig)
        print(f"render-drawing: render failed: {exc}", file=sys.stderr)
        sys.exit(1)

    if region:
        x0, x1, y0, y1 = region
        ax.set_xlim(x0, x1)
        ax.set_ylim(y0, y1)
    ax.set_aspect("equal")
    ax.set_axis_off()

    try:
        fig.savefig(a.out, dpi=a.dpi, facecolor=style["bg"])
    except Exception as exc:
        plt.close(fig)
        print(f"render-drawing: failed to write {a.out}: {exc}", file=sys.stderr)
        sys.exit(1)
    plt.close(fig)

    shown = "all layers" if only is None else f"only {sorted(only)}"
    if hide:
        shown += f", hiding {sorted(hide)}"
    print(f"rendered {a.region or 'whole drawing'} · {shown} · style={a.style} → {a.out}")
    if dangling["count"]:
        print(f"  NOTE: {dangling['count']} INSERT(s) reference missing block "
              f"definition(s) (skipped; likely a DWG→DXF conversion gap): "
              f"{sorted(dangling['names'])[:6]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

_rc=0
python3 "$_pyscript" "$dxf_input" "$@" || _rc=$?
case "$_rc" in
  0) exit 0 ;;
  2) exit 2 ;;
  *) exit 4 ;;
esac
