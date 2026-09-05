#!/usr/bin/env bash
# hook-stop-retro-gate.sh — installable Stop-hook wrapper for §18 retro enforcement.
#
# Install: copy to <TARGET>/.claude/hooks/retro-gate-stop.sh (research-sdd-init.sh does this).
# The init script replaces <KIT> and <TARGET> with absolute paths at install time.
# Register in <TARGET>/.claude/settings.json under hooks.Stop (see init output for snippet).
#
# Behaviour: pipes stdin (Stop-hook JSON) to retro-gate.sh <TARGET>.
# Always exits 0 (hook contract). BLOCK = stdout {"decision":"block","reason":"..."}.
#
# §8 propose-never-apply: the script itself is installed by the operator; never auto-edited.

KIT="<KIT>"       # replaced by research-sdd-init.sh: absolute path to the kit root
TARGET="<TARGET>" # replaced by research-sdd-init.sh: absolute path to this research target

exec "$KIT/toolbelt/retro-gate.sh" "$TARGET"
