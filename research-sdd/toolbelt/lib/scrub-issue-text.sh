#!/usr/bin/env bash
# scrub-issue-text.sh — pre-mutation privacy scrub for text that is about to be written to a public
# issue tracker (kit issue #1707). Sourced (never executed); exports: scrub_issue_text,
# scrub_issue_text_count.
#
# Doctrine: a privacy scan runs BEFORE the first remote write, never after (B30 §30.6). The scrub is a
# PURE filter — stdin -> stdout, no environment reads, no files, no network.
#
#   scrub_issue_text          stdin text -> scrubbed text on stdout
#   scrub_issue_text_count    stdin text -> `redactions: N` on stdout (the typed count of replacements
#                             scrub_issue_text makes on the same input; `redactions: 0` = "looked, found
#                             nothing")
#
# Redaction classes (each replacement counts once):
#   path     an absolute HOME path (/home/<u>/..., /Users/<u>/..., /root/..., /mnt/<d>/Users/<u>/...,
#            C:\Users\<u>\...) -> `<path>`. The whole token goes: the tail of a home path names private
#            projects and checkouts, not only the user name.
#   email    an email-shaped substring -> `<email>`, unconditionally.
#   secret   a `KEY=VALUE` token whose KEY names a credential (contains SECRET, TOKEN, PASSWORD, PASSWD,
#            CREDENTIAL, APIKEY, API_KEY, PRIVATE_KEY, ACCESS_KEY, AUTH, COOKIE, BEARER or SESSION) ->
#            `KEY=<redacted>`; and a bare credential-shaped token (GitHub ghp_/gho_/ghu_/ghs_/ghr_/
#            github_pat_, `sk-` API keys, AWS `AKIA...` ids) -> `<redacted>`.
#
# Allowlist (never redacted, by construction): repo-relative paths (`research-sdd/toolbelt/x.sh`),
# `$RESEARCH_HOME/...` and `${RESEARCH_HOME}/...`, URLs (https://github.com/owner/repo/...), issue and
# PR refs (`#1707`, `owner/repo#12`), and non-credential `NAME=value` tokens such as `MUTANT_SYNTAX=none`
# or `STAGE_RETRO_ISSUES_LIST_LIMIT=5` — kit env knobs are public vocabulary, so they are not scrubbed.
# A home path is only recognised after a boundary (start of line, whitespace, quote, backtick, `(`, `=`,
# `,`, `<`, `[`), so `research-sdd/home/x` and `https://host/home/x` are left alone.
#
# The awk program is POSIX (no interval expressions, no gawk extensions): it runs under mawk.

# Idempotent: safe to source more than once.
if ! declare -F scrub_issue_text >/dev/null 2>&1; then

  # _scrub_issue_awk <mode>   mode=text -> scrubbed text · mode=count -> `redactions: N`
  _scrub_issue_awk() {
    awk -v mode="$1" '
    # first match of re in s that starts at line start or right after a boundary character
    # (sets RSTART/RLENGTH like match()); returns 0 and RSTART=0 when none.
    BEGIN {
      # Home-rooted absolute paths. The tail after the user dir is part of the token. \047 = a single
      # quote (the program lives inside a shell single-quoted string). In a dynamic-regex string a
      # literal backslash is written four times.
      PATHRE = "(/home/[^/[:space:]]+|/Users/[^/[:space:]]+|/mnt/[a-z]/Users/[^/[:space:]]+|[A-Za-z]:[\\\\]Users[\\\\][^\\\\[:space:]]+)([/\\\\][^[:space:]`\"\047),;>]*)?|/root/[^[:space:]`\"\047),;>]*"
    }
    function bmatch(s,    off, rest, st, ln) {
      off = 0; rest = s
      while (match(rest, PATHRE)) {
        st = RSTART; ln = RLENGTH
        if (st + off == 1 || substr(s, st + off - 1, 1) ~ /[[:space:]"`(=,<\[]/) {
          RSTART = st + off; RLENGTH = ln; return RSTART
        }
        off += st; rest = substr(rest, st + 1)
      }
      RSTART = 0; RLENGTH = -1; return 0
    }
    function scrub(line,    out, k, tok) {
      out = ""
      # 1) bare credential-shaped tokens (a word-internal hit is not a token)
      while (match(line, /(gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-]+|AKIA[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])/)) {
        if (RSTART > 1 && substr(line, RSTART - 1, 1) ~ /[A-Za-z0-9_]/) {
          out = out substr(line, 1, RSTART); line = substr(line, RSTART + 1); continue
        }
        out = out substr(line, 1, RSTART - 1) "<redacted>"; line = substr(line, RSTART + RLENGTH); count++
      }
      line = out line; out = ""
      # 2) credential-named KEY=VALUE
      while (match(line, /[A-Z][A-Z0-9_]*=[^[:space:]`"\047),;]+/)) {
        tok = substr(line, RSTART, RLENGTH); k = tok; sub(/=.*/, "", k)
        if (k ~ /(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|APIKEY|API_KEY|PRIVATE_KEY|ACCESS_KEY|AUTH|COOKIE|BEARER|SESSION)/ && tok != k "=<redacted>") {
          out = out substr(line, 1, RSTART - 1) k "=<redacted>"; count++
        } else out = out substr(line, 1, RSTART + RLENGTH - 1)
        line = substr(line, RSTART + RLENGTH)
      }
      line = out line; out = ""
      # 3) emails
      while (match(line, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z][A-Za-z]+/)) {
        out = out substr(line, 1, RSTART - 1) "<email>"; line = substr(line, RSTART + RLENGTH); count++
      }
      line = out line; out = ""
      # 4) absolute home paths, after a boundary
      while (bmatch(line)) {
        out = out substr(line, 1, RSTART - 1) "<path>"; line = substr(line, RSTART + RLENGTH); count++
      }
      return out line
    }
    { s = scrub($0); if (mode == "text") print s }
    END { if (mode == "count") printf "redactions: %d\n", count + 0 }
    '
  }

  scrub_issue_text() { _scrub_issue_awk text; }
  scrub_issue_text_count() { _scrub_issue_awk count; }
fi
