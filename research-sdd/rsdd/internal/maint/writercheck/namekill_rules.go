package writercheck

import "regexp"

// The data of the name-kill scan: the regular expressions, in the notation of the awk program of the bash tool (POSIX
// ERE; RE2 reads the same text). The verdicts are pinned to the hook's --strict-name-kill
// (templates/hook-pretool-pkill-guard.sh) by tests/fixtures/kit-writer-check/name-kill-corpus.txt.
//
// In shell the tool name must be in COMMAND position (line start, after ; & | ( { $( `bash -c '` or then/do/else/if/
// while/sudo/exec/env/nohup/xargs/time/timeout/command/nice, past flags, numbers and VAR=x), so prose, grep patterns
// and JSON fixtures that merely mention it do not trip. In python/js/ts the argv-list form ["tool", ...] and a call
// such as system(...tool...) count too. The [x] bracket trick keeps the tool names out of a plain-text search for
// them.
const (
	keyword = `(then|do|else|elif|if|while|until|sudo|exec|env|nohup|xargs|time|timeout|command|nice)`
	// position: where a command may start, then blanks.
	position = "(^|[;&|(`{]|[$][(]|(^|[^[:alnum:]_-])" + keyword + `|-c[[:space:]]+["']` + `)[[:space:]]*`
	// optionWords: flags, numbers and VAR=value words between the position and the command name.
	optionWords = `(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|-[^[:space:]]*|[0-9]+)[[:space:]]+)*`

	byName   = position + optionWords + `(/[^[:space:]]*/)?([p]kill|[k]illall)([^[:alnum:]_.-]|$)`
	killAll  = position + optionWords + `[k]ill[[:space:]]+(-[A-Za-z0-9]+[[:space:]]+|--[[:space:]]+|-s[[:space:]]+[A-Za-z0-9]+[[:space:]]+)*-1([^0-9]|$)`
	pipeKill = `([p]grep|[p]idof)[^&|;]*\|[[:space:]]*(xargs|while)[^&]*(^|[^[:alnum:]_-])[k]ill([^[:alnum:]_-]|$)`
	subKill  = "(^|[^[:alnum:]_-])[k]ill[^;|&]*(\\$\\(|`)[[:space:]]*([p]grep|[p]idof)"
	argvForm = `["']([p]kill|[k]illall)["']`
	callForm = `(system|run|call|Popen|check_call|check_output|exec[A-Za-z]*|spawn[A-Za-z]*)[(][^)]*["' ][p]kill`

	// allowMarker on the line opts it out; a comment-only line is never scanned.
	allowMarker = `writer-check:[[:space:]]*allow-name-kill`
	commentLine = `^[[:space:]]*(#|//)`

	shellFiles  = `\.(sh|bash|py|mjs|cjs|js|ts)$`
	scriptFiles = `\.(py|mjs|cjs|js|ts)$`
)

var (
	reByName   = regexp.MustCompile(byName)
	reKillAll  = regexp.MustCompile(killAll)
	rePipeKill = regexp.MustCompile(pipeKill)
	reSubKill  = regexp.MustCompile(subKill)
	reArgv     = regexp.MustCompile(argvForm)
	reCall     = regexp.MustCompile(callForm)
	reAllow    = regexp.MustCompile(allowMarker)
	reComment  = regexp.MustCompile(commentLine)
	reScanned  = regexp.MustCompile(shellFiles)
	reScripts  = regexp.MustCompile(scriptFiles)
)
