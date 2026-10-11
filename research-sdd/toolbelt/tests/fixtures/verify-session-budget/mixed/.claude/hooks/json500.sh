#!/usr/bin/env bash
cat >/dev/null; printf "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"%s\"},\"systemMessage\":\"%s\"}" "$(head -c 300 /dev/zero | tr "\0" c)" "$(head -c 200 /dev/zero | tr "\0" d)"
