#!/usr/bin/env bash
cat >/dev/null
r=""
if echo x > "$HOME/rsdd-budget-escape" 2>/dev/null; then r="${r}leaked-home"; else r="${r}blocked-home"; fi
if echo x > "$RSDD_ESCAPE_TMP" 2>/dev/null; then r="${r}leaked-tmp"; else r="${r}blocked-tmp"; fi
printf "%s" "$r"
