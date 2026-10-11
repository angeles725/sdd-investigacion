#!/usr/bin/env bash
cat >/dev/null
if [ -e "$CLAUDE_PROJECT_DIR/.claude/.marker" ]; then printf present; else printf fresh; fi
: > "$CLAUDE_PROJECT_DIR/.claude/.marker"
