#!/usr/bin/env bash
# gh-stub.sh: the fake `gh` of the stage-retro-issues differential (a dynamic form of the old suite's mk_gh_stub).
# Every behaviour is chosen by the environment so ONE script serves the legacy bash run and the Go run, each with
# its own STUB_DIR (call log + state files), and the two can be compared call for call.
#   STUB_DIR     required: gh.log (one `gh <args>` line per call) and the state files below live here
#   STUB_MODE    issue-list/create behaviour (default nomatch): match matchclosed nomatch listfail listempty
#                createfail createnourl createfailcreated createfailrelistfail createfailsecond fuzzyother
#                fuzzyotherclosed fuzzylongid fuzzyplusexact crlfsig sigonly nullbody badjson matchsig
#                matchsigclosed failsig page2 noauth
#   STUB_SIGPAT  the --search substring that matchsig/matchsigclosed/failsig react to
#   STUB_LABEL   label probe: exists (default) existsupper racewin fuzzyonly listfail listempty createfail failjson
#                missing
#   STUB_VIEW    `gh issue view <N> --json body` read-back: ok (default) nosig empty fail
# Tracker lookups (the unclassifiable tracker, `--json number,state,body` and `--json state,body` with a `Unclassifiable`
# needle): trkset answers the by-signature lookup (all issues of the retro's tracker), trksig the item-set lookup.
# State files in STUB_DIR (all optional): trkset trksig occ occfail occnoend occ2 (occurrence list), commentfail(.N)
# commentghost(.N) commentnourl commentfailwrote, viewfail viewfailafter.
D="${STUB_DIR:?STUB_DIR is required}"
MODE="${STUB_MODE:-nomatch}"; LABEL="${STUB_LABEL:-exists}"; VIEW="${STUB_VIEW:-ok}"; SIGPAT="${STUB_SIGPAT:-}"
printf '%s\n' "gh $*" >> "$D/gh.log"
if [ "$MODE" = noauth ]; then
  case " $* " in *" auth status "*) exit 1 ;; *) exit 0 ;; esac
fi
_sig=""; _prev=""
for _a in "$@"; do [ "$_prev" = "--search" ] && _sig="$_a"; _prev="$_a"; done
save_body() { local _p="" _x; for _x in "$@"; do [ "$_p" = "--body" ] && printf "%s" "$_x" > "$D/body"; _p="$_x"; done; }
_validate_view() {
  local _sk="" _a _n=0 _repo=0 _json=0 _jq=0
  for _a in "$@"; do
    if [ -n "$_sk" ]; then
      case "$_sk" in json) [ "$_a" = body ] && _json=1 ;; jq) [ "$_a" = .body ] && _jq=1 ;; repo) _repo=1 ;; esac
      _sk=""; continue
    fi
    case "$_a" in
      issue|view) ;;
      --repo) _sk=repo ;; --json) _sk=json ;; --jq) _sk=jq ;;
      [0-9]*) case "$_a" in *[!0-9]*) echo "gh stub: bad issue number: $_a" >&2; return 1 ;; esac; _n=1 ;;
      *) echo "gh stub: unknown flag: $_a" >&2; return 1 ;;
    esac
  done
  [ "$_n$_repo$_json$_jq" = 1111 ] || { echo "gh stub: issue view needs <N> --repo R --json body --jq .body" >&2; return 1; }
}
_sig="${_sig#\"}"; _sig="${_sig%\"}"
reply() { printf '[{"body":"Delta text\\n\\n**Target:** x\\n\\n---\\n%s\\nPart of backlog-first rollout #557","state":"%s"}]\n' "$_sig" "$1"; }
fuzzy_other() { printf '[{"body":"Other delta\\n\\n---\\nSource retro: niagara-%s\\nPart of backlog-first rollout #557","state":"%s"}]\n' "${_sig#Source retro: }" "$1"; }
fuzzy_longid() { printf '[{"body":"Other row\\n\\n---\\n%s0\\nPart of backlog-first rollout #557","state":"%s"}]\n' "$_sig" "$1"; }
fuzzy_plus_exact() { printf '[{"body":"Other\\n---\\nSource retro: niagara-%s","state":"OPEN"},{"body":"x\\n---\\n%s\\ntail","state":"OPEN"}]\n' "${_sig#Source retro: }" "$_sig"; }
crlf_reply() { printf '[{"body":"x\\n---\\n%s\\r\\ntail","state":"OPEN"}]\n' "$_sig"; }
create_alt() { local n; n="$(cat "$D/cnt" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$D/cnt"; if [ "$n" -ge 2 ]; then printf 'ERROR: GraphQL request failed\n'; return 1; fi; printf 'https://github.com/r/issues/%s\n' "$n"; }
sigonly_reply() { printf '[{"state":"OPEN","body":"%s"}]\n' "$_sig"; }
_validate_list() {
  local _sk="" _a _f
  for _a in "$@"; do
    if [ -n "$_sk" ]; then
      case "$_sk" in
        json)  for _f in ${_a//,/ }; do case "$_f" in state|body|number|title) ;; *) echo "gh stub: unknown JSON field: $_f" >&2; return 1 ;; esac; done ;;
        limit) case "$_a" in ''|*[!0-9]*|0) echo "gh stub: invalid --limit: $_a" >&2; return 1 ;; esac ;;
        state) case "$_a" in open|closed|all) ;; *) echo "gh stub: invalid --state: $_a" >&2; return 1 ;; esac ;;
      esac
      _sk=""; continue
    fi
    case "$_a" in
      issue|list) ;;
      --repo|--search|--jq|--label) _sk=val ;;
      --state) _sk=state ;;
      --json)  _sk=json ;;
      --limit) _sk=limit ;;
      *) echo "gh stub: unknown flag: $_a" >&2; return 1 ;;
    esac
  done
}
page2_reply() {
  local _l="" _p="" _a _n _i _o=""
  for _a in "$@"; do [ "$_p" = "--limit" ] && _l="$_a"; _p="$_a"; done
  _n=2; [ -n "$_l" ] && [ "$_l" -lt 2 ] && _n="$_l"
  for ((_i = 1; _i <= _n; _i++)); do _o="${_o}${_o:+,}{\"body\":\"unrelated issue $_i\",\"state\":\"OPEN\"}"; done
  printf '[%s]\n' "$_o"
}
occ_list() {
  local _on; _on="$(cat "$D/occn" 2>/dev/null || echo 0)"; _on=$((_on+1)); echo "$_on" > "$D/occn"
  [ "$_on" -ge 2 ] && [ -f "$D/occ2" ] && { cat "$D/occ2"; return 0; }
  [ -f "$D/occfail" ] && { printf 'gh: occurrence lookup failed\n' >&2; return 1; }
  [ -f "$D/occnoend" ] && { printf '[{"number":55,"state":"OPEN","title":"cut off here\n'; return 0; }
  if [ -f "$D/occ" ]; then cat "$D/occ"; else printf '[]\n'; fi
  return 0
}
occ_comment() {
  local _p="" _n="" _b="" _x
  for _x in "$@"; do
    [ "$_p" = "--body" ] && _b="$_x"
    case "$_x" in [0-9]*) _n="$_x" ;; esac
    _p="$_x"
  done
  [ -f "$D/commentfailwrote" ] && { printf '%s\n' "$_b" >> "$D/comments.$_n"; printf 'gh: timeout\n' >&2; return 1; }
  [ -f "$D/commentfail" ] || [ -f "$D/commentfail.$_n" ] && { printf 'gh: comment failed\n' >&2; return 1; }
  [ -f "$D/commentghost" ] || [ -f "$D/commentghost.$_n" ] || printf '%s\n' "$_b" >> "$D/comments.$_n"
  [ -f "$D/commentnourl" ] && { printf 'done\n'; return 0; }
  printf 'https://github.com/r/issues/%s#issuecomment-1\n' "$_n"
}
occ_view() {
  local _n="" _x
  for _x in "$@"; do case "$_x" in [0-9]*) _n="$_x" ;; esac; done
  [ -f "$D/viewfail" ] && { printf 'gh: HTTP 502\n' >&2; return 1; }
  if [ -f "$D/viewfailafter" ]; then
    local _vc; _vc="$(cat "$D/vcnt" 2>/dev/null || echo 0)"; _vc=$((_vc+1)); echo "$_vc" > "$D/vcnt"
    [ "$_vc" -ge "$(cat "$D/viewfailafter")" ] && { printf 'gh: HTTP 502\n' >&2; return 1; }
  fi
  [ -f "$D/comments.$_n" ] && cat "$D/comments.$_n"
  return 0
}
label_search() { local _s="" _p="" _a; for _a in "$@"; do [ "$_p" = "--search" ] && _s="$_a"; _p="$_a"; done; printf '%s' "$_s"; }
case " $* " in *" issue list "*) _validate_list "$@" || exit 2 ;; esac
case " $* " in
  *" auth status "*) exit 0 ;;
  *" label list "*)
    case "$LABEL" in
      exists) printf '[{"name":"%s"}]\n' "$(label_search "$@")"; exit 0 ;;
      existsupper) printf '[{"name":"%s"}]\n' "$(label_search "$@" | tr a-z A-Z)"; exit 0 ;;
      racewin) _c="$(cat "$D/lcnt" 2>/dev/null || echo 0)"; _c=$((_c+1)); echo "$_c" > "$D/lcnt"
               if [ "$_c" -ge 2 ]; then printf '[{"name":"%s"}]\n' "$(label_search "$@")"; else printf '[]\n'; fi; exit 0 ;;
      fuzzyonly) printf '[{"name":"%s-extra"}]\n' "$(label_search "$@")"; exit 0 ;;
      listfail) printf 'gh: label list failed\n' >&2; exit 1 ;;
      listempty) exit 0 ;;
      failjson) printf '[]\n'; exit 1 ;;
      *) printf '[]\n'; exit 0 ;;
    esac ;;
  *" label create "*)
    if [ "$LABEL" = createfail ] || [ "$LABEL" = racewin ]; then printf 'gh: label create failed\n' >&2; exit 1; fi
    exit 0 ;;
  *" issue list "*" number,state,title "*) occ_list; exit $? ;;
  *" issue list "*"Unclassifiable tracker:"*" number,state,body "*) [ -f "$D/trkset" ] && { cat "$D/trkset"; exit 0; } ;;&
  *" issue list "*"Unclassifiable item set:"*) [ -f "$D/trksig" ] && { cat "$D/trksig"; exit 0; } ;;&
  *" issue comment "*) occ_comment "$@"; exit $? ;;
  *" issue view "*" --json comments "*) occ_view "$@"; exit $? ;;
  *" issue list "*)
    case "$MODE" in
      match) reply OPEN ;;
      fuzzyother) fuzzy_other OPEN ;;
      fuzzyotherclosed) fuzzy_other CLOSED ;;
      fuzzylongid) fuzzy_longid OPEN ;;
      fuzzyplusexact) fuzzy_plus_exact ;;
      crlfsig) crlf_reply ;;
      sigonly) sigonly_reply ;;
      nullbody) printf '[{"body":null,"state":"OPEN"}]\n' ;;
      badjson) printf '[{"body":"cut off here\n' ;;
      matchclosed) case " $* " in *" --state open "*) printf '[]\n' ;; *) reply CLOSED ;; esac ;;
      matchsig) case " $* " in *"$SIGPAT"*) reply OPEN ;; *) printf '[]\n' ;; esac ;;
      matchsigclosed) case " $* " in *"$SIGPAT"*) reply CLOSED ;; *) printf '[]\n' ;; esac ;;
      failsig) case " $* " in *"$SIGPAT"*) printf 'gh: error: something went wrong\n' >&2; exit 1 ;; *) printf '[]\n' ;; esac ;;
      page2) page2_reply "$@" ;;
      listfail) printf 'gh: error: something went wrong\n' >&2; exit 1 ;;
      createfailcreated) if [ -f "$D/created" ]; then reply OPEN; else printf '[]\n'; fi ;;
      createfailrelistfail) if [ -f "$D/created" ]; then printf 'gh: error: boom\n' >&2; exit 1; else printf '[]\n'; fi ;;
      listempty) : ;;
      *) printf '[]\n' ;;
    esac
    exit 0 ;;
  *" issue create "*)
    case "$MODE" in
      createfail) printf 'ERROR: GraphQL request failed\n'; exit 1 ;;
      createnourl) save_body "$@"; printf 'Created!\n'; exit 0 ;;
      createfailcreated|createfailrelistfail) : > "$D/created"; printf 'ERROR: timeout after write\n'; exit 1 ;;
      createfailsecond) save_body "$@"; create_alt; exit $? ;;
      *) save_body "$@"; printf 'https://github.com/r/issues/99\n'; exit 0 ;;
    esac ;;
  *" issue view "*)
    _validate_view "$@" || exit 2
    case "$VIEW" in
      ok) [ -f "$D/body" ] || { printf 'gh: could not resolve to an issue\n' >&2; exit 1; }; cat "$D/body"; printf '\n'; exit 0 ;;
      nosig) printf 'Some other body without the signature\n'; exit 0 ;;
      empty) exit 0 ;;
      fail) printf 'gh: HTTP 502\n' >&2; exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
