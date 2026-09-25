#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STOP, but the campaign queue was NEVER
# declared for any focus — the real script's shape when no `## Campaign queue` section was
# ever created (METHODOLOGY §8c: "most real multi-focus corpora reach campaign STOP without
# one" — niagara-research measured 0 of 89 RESEARCH-STATE*.md files populating it). Used to
# test score-loop-transcript.sh's C4 n/a path (kit issue #1107): "queue empty" cannot be
# verified when there is no queue to inspect, so this must NOT vacuously pass.
if [[ "${2:-}" == "--next" ]]; then
  echo "STOP | read-only-investigable exhausted (0)"
else
  echo "  campaign        : none (2 active focuses, 0 with a queue)"
fi
