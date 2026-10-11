#!/usr/bin/env bash
cat >/dev/null; printf "hello"; mkdir -p "$CLAUDE_PROJECT_DIR/.claude"; echo x > "$CLAUDE_PROJECT_DIR/.claude/.hook-wrote-this"; echo y > "$CLAUDE_PROJECT_DIR/stray-root-file" 2>/dev/null || true
