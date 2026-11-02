package adapter

import (
	"crypto/sha256"
	hexenc "encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	pathpkg "path"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// Port of analysis_manifest.py: create, validate and verify analysis-manifest.v1 documents.
// It only reads artifacts and supplied run metadata; it never launches the target or the tool.
// Every check keeps the order and the message of the Python. Documents are decoded with encoding/json
// (numbers stay json.Number, so integers keep every digit) into obj values.

const SchemaVersion = "analysis-manifest.v1"

// pyWS is the class Python's \s (and str.isspace) means for str patterns.
const pyWS = `\t\n\v\f\r \x1c-\x1f\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}`

// Under IGNORECASE Python also lets ASCII "i" match U+0130 and U+0131; Go's folding does not, so those
// two are added wherever a pattern spells the letter i or a class that contains it.
const ii = "İı"

var (
	hashRE     = regexp.MustCompile(`\Asha256:[0-9a-f]{64}\z`)
	locationRE = regexp.MustCompile(`\A([^:]+):([1-9][0-9]*)(?:-([1-9][0-9]*))?\z`)
	schemeRE   = regexp.MustCompile(`\A[A-Za-z][A-Za-z0-9+.-]*:`)

	secretKeyRE = regexp.MustCompile(`(?i)(secret|token|passw(?:or)?d|credent[i` + ii + `]al|pr[i` + ii + `]vate|ap[i` + ii + `][_-]?key|auth|cook[i` + ii + `]e)`)

	secretValueRE = regexp.MustCompile(`(?i)(bearer[` + pyWS + `]+[^` + pyWS + `]+` +
		`|ghp_[A-Za-z0-9` + ii + `]{20,}` +
		`|xoxb-[A-Za-z0-9` + ii + `-]{10,}` +
		`|eyJ[A-Za-z0-9` + ii + `_-]{10,}\.` +
		`|AK[i` + ii + `]A[0-9A-Z` + ii + `]{16}` +
		`|-----BEG[i` + ii + `]N[` + pyWS + `]+[^-]*PR[i` + ii + `]VATE KEY-----` +
		`|(?:secret|token|passw(?:or)?d|ap[i` + ii + `][_-]?key|author[i` + ii + `]zat[i` + ii + `]on|cook[i` + ii + `]e)[` + pyWS + `]*[:=])`)

	// Python's $ also matches before a trailing newline.
	secretOptionRE = regexp.MustCompile(`(?i)(?:\A|[-_])(?:passw(?:or)?d|token|secret|credent[i` + ii + `]al|pr[i` + ii + `]vate[-_]?key|ap[i` + ii + `][-_]?key|author[i` + ii + `]zat[i` + ii + `]on|cook[i` + ii + `]e)(?:\n?\z|[-_])`)
)

var envAllowlist = map[string]bool{
	"HOME": true, "JAVA_HOME": true, "LANG": true, "LC_ALL": true, "PATH": true, "SHELL": true, "TMPDIR": true, "TZ": true, "USER": true,
	"HOMEBREW_PREFIX": true, "RSDD_BREW_PREFIX": true, "RSDD_PROBE_TIMEOUT": true,
	"RESEARCH_SDD_JAVA_HOME": true, "RESEARCH_SDD_TOOL_HOME": true,
	"RSDD_DECOMPILE_MAX_HEAP": true,
	"XDG_CACHE_HOME":          true, "XDG_CONFIG_HOME": true, "XDG_DATA_HOME": true,
}

type obj = map[string]any

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// asInt is isinstance(v, int) (not bool) for a decoded JSON value.
func asInt(v any) (*big.Int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return nil, false
	}
	return new(big.Int).SetString(string(n), 10) // fails for 1.0 and 1e5, which are not ints
}

func isNonNegInt(v any) bool {
	n, ok := asInt(v)
	return ok && n.Sign() >= 0
}

func num(n int64) json.Number { return json.Number(strconv.FormatInt(n, 10)) }

func reprStrings(xs []string) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = pyRepr(x)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// reprValue is repr() of a decoded JSON value, as far as the one message that quotes a document value
// needs it (an unknown schema_version).
func reprValue(v any) string {
	switch x := v.(type) {
	case nil:
		return "None"
	case bool:
		if x {
			return "True"
		}
		return "False"
	case string:
		return pyRepr(x)
	case json.Number:
		return string(x)
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = reprValue(e)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case obj:
		parts := []string{}
		for _, k := range sortedKeys(x) {
			parts = append(parts, pyRepr(k)+": "+reprValue(x[k]))
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return fmt.Sprint(v)
}

// keysOf is _keys: the value must be an object with exactly these keys.
func keysOf(v any, expected []string, ctx string) (obj, error) {
	d, ok := v.(obj)
	var missing, extra []string
	for _, k := range expected {
		if _, has := d[k]; !ok || !has {
			missing = append(missing, k)
		}
	}
	want := map[string]bool{}
	for _, k := range expected {
		want[k] = true
	}
	for k := range d {
		if !want[k] {
			extra = append(extra, k)
		}
	}
	if ok && len(missing) == 0 && len(extra) == 0 {
		return d, nil
	}
	sort.Strings(missing)
	sort.Strings(extra)
	return nil, mfail(fmt.Sprintf("%s fields invalid; missing=%s, extra=%s", ctx, reprStrings(missing), reprStrings(extra)))
}

// textOf is _text: a string with something other than whitespace in it.
func textOf(v any, ctx string) (string, error) {
	s, ok := v.(string)
	if !ok || strings.TrimFunc(s, pySpace) == "" {
		return "", mfail(ctx + " must be a non-empty string")
	}
	return s, nil
}

// relativePath is _relative: a canonical artifact-relative path, judged after URL-decoding and
// NFKC-normalising it until it stops changing.
func relativePath(v any, ctx string) (string, error) {
	text, err := textOf(v, ctx)
	if err != nil {
		return "", err
	}
	normalized, stable := text, false
	for i := 0; i < 8; i++ {
		decoded := nfkc(pyUnquote(normalized))
		if decoded == normalized {
			stable = true
			break
		}
		normalized = decoded
	}
	if !stable {
		return "", mfail(ctx + " exceeds normalization limit")
	}
	hasDotDot := false
	for _, part := range pyParts(normalized) {
		if part == ".." {
			hasDotDot = true
		}
	}
	if strings.Contains(normalized, "\\") || schemeRE.MatchString(normalized) || strings.HasPrefix(normalized, "/") || hasDotDot || pyNorm(normalized) != normalized {
		return "", mfail(ctx + " must be a canonical artifact-relative path")
	}
	return text, nil
}

// analysisArtifactPath is _analysis_artifact_path: a relative artifact path or a canonical absolute one.
func analysisArtifactPath(v any, ctx string) (string, error) {
	text, err := textOf(v, ctx)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(text, "/") {
		return relativePath(text, ctx)
	}
	for _, part := range pyParts(text) {
		if part == ".." {
			return "", mfail(ctx + " must be a canonical absolute or artifact-relative path")
		}
	}
	if strings.HasPrefix(text, "//") || strings.Contains(text, "\\") || pyNorm(text) != text {
		return "", mfail(ctx + " must be a canonical absolute or artifact-relative path")
	}
	return text, nil
}

func safeArgv(v any) ([]string, error) {
	list, ok := v.([]any)
	if !ok || len(list) == 0 {
		return nil, mfail("argv must be a non-empty string array")
	}
	argv := make([]string, len(list))
	for i, item := range list {
		s, ok := item.(string)
		if !ok {
			return nil, mfail("argv must be a non-empty string array")
		}
		argv[i] = s
	}
	for i, item := range argv {
		option, _, _ := strings.Cut(item, "=")
		if secretValueRE.MatchString(item) || (strings.HasPrefix(option, "-") && secretOptionRE.MatchString(strings.TrimLeft(option, "-"))) {
			return nil, mfail(fmt.Sprintf("argv item %d is secret-like; redact before capture", i))
		}
	}
	return argv, nil
}

func sanitizeEnvironment(v any) (map[string]string, error) {
	d, ok := v.(obj)
	if !ok {
		return nil, mfail("environment must be an object")
	}
	clean := map[string]string{}
	for _, key := range sortedKeys(d) {
		if !envAllowlist[key] || secretKeyRE.MatchString(key) {
			return nil, mfail("environment key is not allowlisted or is secret-like: " + pyRepr(key))
		}
		item, ok := d[key].(string)
		if !ok || secretValueRE.MatchString(item) {
			return nil, mfail("environment value is invalid or secret-like for " + key)
		}
		clean[key] = item
	}
	return clean, nil
}

// evidenceLocation is _evidence_location: path:start[-end].
func evidenceLocation(v any) (string, *big.Int, *big.Int, error) {
	s, _ := v.(string)
	m := locationRE.FindStringSubmatch(s)
	if _, isStr := v.(string); !isStr || m == nil {
		return "", nil, nil, mfail("finding evidence location is invalid")
	}
	path, err := relativePath(m[1], "evidence location")
	if err != nil {
		return "", nil, nil, err
	}
	start, _ := new(big.Int).SetString(m[2], 10)
	end := start
	if m[3] != "" {
		end, _ = new(big.Int).SetString(m[3], 10)
	}
	return path, start, end, nil
}

func boundArgvIndex(v any, argv []string, path string, seen map[int]bool) (int, error) {
	n, ok := asInt(v)
	if !ok || n.Sign() <= 0 || !n.IsInt64() || n.Int64() >= int64(len(argv)) || seen[int(n.Int64())] {
		return 0, mfail("analysis artifact argv_index must be unique, nonzero, and in range")
	}
	i := int(n.Int64())
	if argv[i] != path {
		return 0, mfail("analysis artifact path must equal its argv token")
	}
	seen[i] = true
	return i, nil
}

type fileID struct {
	resolved string
	size     int64
	sha      string
	lines    int64
}

// Test seams: the descriptor stat and the hook that runs after a file was hashed.
var (
	fstatFn           = statFD
	readlinkFn        = os.Readlink
	afterIdentityHook func(path string)
)

const readChunk = 1024 * 1024

// fileIdentity hashes one stable descriptor and returns the resolved path, size, digest and line count.
// root, when set, is the directory the opened file must live under.
func fileIdentity(path string, root *string, env Env) (fileID, error) {
	fd, err := openNoFollow(path)
	if err != nil {
		return fileID{}, mfail("file identity cannot be opened safely")
	}
	defer func() { _ = closeFD(fd) }()
	resolved := resolveFD(fd, path, env)
	if root != nil && !isRelativeTo(resolved, *root) {
		return fileID{}, mfail("opened file escapes analysis root")
	}
	before, err := fstatFn(fd)
	if err != nil {
		return fileID{}, osError(err, "")
	}
	if before.mode&0o170000 != 0o100000 {
		return fileID{}, mfail("file identity is not a regular file")
	}
	h := sha256.New()
	buf := make([]byte, readChunk)
	var total, newlines int64
	var last byte
	for {
		n, err := readFD(fd, buf)
		if err != nil {
			return fileID{}, osError(err, "")
		}
		if n == 0 {
			break
		}
		h.Write(buf[:n])
		total += int64(n)
		for _, b := range buf[:n] {
			if b == '\n' {
				newlines++
			}
		}
		last = buf[n-1]
	}
	after, err := fstatFn(fd)
	if err != nil {
		return fileID{}, osError(err, "")
	}
	if before != after || total != before.size {
		return fileID{}, mfail("file changed while hashing")
	}
	lines := newlines
	if total > 0 && last != '\n' {
		lines++
	}
	if afterIdentityHook != nil {
		afterIdentityHook(path)
	}
	return fileID{resolved, total, "sha256:" + hexenc.EncodeToString(h.Sum(nil)), lines}, nil
}

// resolveFD is Path(/proc/self/fd/N).resolve(): where the opened descriptor really lives. Without
// /proc it resolves the path the descriptor was opened from.
func resolveFD(fd int, path string, env Env) string {
	link, err := readlinkFn("/proc/self/fd/" + strconv.Itoa(fd))
	if err != nil {
		link = env.absPath(path)
	}
	r, _ := realpath(link, false, env.Cwd)
	return r
}

func artifactIdentity(root string, rel any, ctx string, analysisTool bool, env Env) (obj, int64, error) {
	var recorded string
	var err error
	if analysisTool {
		recorded, err = analysisArtifactPath(rel, ctx)
	} else {
		recorded, err = relativePath(rel, ctx)
	}
	if err != nil {
		return nil, 0, err
	}
	path, constraint := recorded, (*string)(nil)
	if !strings.HasPrefix(recorded, "/") {
		path, constraint = pyJoin(root, recorded), &root
	}
	id, err := fileIdentity(path, constraint, env)
	if err != nil {
		return nil, 0, err
	}
	return obj{"path": recorded, "size": num(id.size), "sha256": id.sha}, id.lines, nil
}

// --- the tool launcher -----------------------------------------------------------------------------

type searchDir struct {
	dir         string
	constrained bool
}

func resolveTool(argv0, claimed, root string, environment map[string]string, env Env) (obj, error) {
	pathDirectories := func() (searchPath []searchDir, err error) {
		for index, entry := range strings.Split(environment["PATH"], ":") {
			expanded := expandUser(entry, env)
			constrained := !strings.HasPrefix(expanded, "/")
			var directory string
			switch {
			case entry == "" || entry == ".":
				directory = root
			case constrained:
				rel, err := relativePath(entry, fmt.Sprintf("environment PATH entry[%d]", index))
				if err != nil {
					return nil, err
				}
				directory = pyJoin(root, rel)
			default:
				directory = expanded
			}
			if constrained {
				r, _ := realpath(directory, false, env.Cwd)
				if !isRelativeTo(r, root) {
					return nil, mfail("relative PATH entry escapes analysis root")
				}
				directory = r
			}
			searchPath = append(searchPath, searchDir{directory, constrained})
		}
		return searchPath, nil
	}
	type found struct {
		path        string
		constrained bool
	}
	candidate := func(value string) (*found, error) {
		p := expandUser(value, env)
		if strings.HasPrefix(p, "/") {
			return &found{p, false}, nil
		}
		if strings.Contains(value, "/") || strings.Contains(value, "\\") {
			rel, err := relativePath(value, "tool command path")
			if err != nil {
				return nil, err
			}
			return &found{pyJoin(root, rel), true}, nil
		}
		dirs, err := pathDirectories()
		if err != nil {
			return nil, err
		}
		for _, d := range dirs {
			option := pyJoin(d.dir, value)
			if isFile(option) {
				return &found{option, d.constrained}, nil
			}
		}
		return nil, nil
	}
	invoked, err := candidate(argv0)
	if err != nil {
		return nil, err
	}
	declared, err := candidate(claimed)
	if err != nil {
		return nil, err
	}
	if invoked == nil {
		return nil, mfail("tool command is unresolved or mismatched")
	}
	invokedPath := pathpkg.Clean(invoked.path)
	if declared == nil {
		return nil, mfail("tool identity does not match argv zero")
	}
	same, err := sameFile(declared.path, invokedPath)
	if err != nil {
		return nil, err
	}
	if !same {
		return nil, mfail("tool identity does not match argv zero")
	}
	before, err := statPath(invokedPath)
	if err != nil {
		return nil, err
	}
	var constraint *string
	if invoked.constrained {
		constraint = &root
	}
	id, err := fileIdentity(invokedPath, constraint, env)
	if err != nil {
		return nil, err
	}
	after, err := statPath(invokedPath)
	if err != nil {
		return nil, err
	}
	if before != after {
		return nil, mfail("tool launcher changed while resolving identity")
	}
	same, err = sameFile(declared.path, id.resolved)
	if err != nil {
		return nil, err
	}
	if !same {
		return nil, mfail("tool launcher changed while resolving identity")
	}
	if !canExec(id.resolved) {
		return nil, mfail("tool launcher is not executable")
	}
	recorded := id.resolved
	if invoked.constrained && strings.Contains(argv0, "/") {
		recorded = argv0
	}
	return obj{"resolved_executable": recorded, "sha256": id.sha}, nil
}

func sameFile(a, b string) (same bool, err error) {
	sa, err := statPath(a)
	if err != nil {
		return
	}
	sb, err := statPath(b)
	if err != nil {
		return
	}
	return sa.dev == sb.dev && sa.ino == sb.ino, nil
}

// --- identity, build, validate, verify -------------------------------------------------------------

// CanonicalBytes is canonical_bytes: sorted compact JSON, non-ASCII kept, one trailing newline.
func CanonicalBytes(v any) ([]byte, error) { return jsonout.CanonicalUnicode(v) }

// manifestIdentity is _identity: the hash of the manifest without its identity and volatile timings.
func manifestIdentity(m obj) (string, error) {
	stable := obj{}
	for k, v := range m {
		if k != "identity" {
			stable[k] = v
		}
	}
	run, ok := stable["run"].(obj)
	if !ok {
		return "", mfail("run must be an object")
	}
	cleaned := obj{}
	for k, v := range run {
		if k != "started_at" && k != "ended_at" && k != "duration_ms" {
			cleaned[k] = v
		}
	}
	stable["run"] = cleaned
	b, err := CanonicalBytes(stable)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return "sha256:" + hexenc.EncodeToString(sum[:]), nil
}

// BuildManifest is build_manifest: validate the spec, hash every artifact and assemble the manifest.
func BuildManifest(spec any, root string, env Env) (obj, error) {
	d, err := keysOf(spec, []string{"schema_version", "input", "tool", "argv", "environment", "run", "stdout_path", "stderr_path", "outputs", "findings", "limitations", "errors", "completeness", "isolation_profile"}, "spec")
	if err != nil {
		return nil, err
	}
	if sv, ok := d["schema_version"].(string); !ok || sv != SchemaVersion {
		return nil, mfail("unknown schema version: " + reprValue(d["schema_version"]))
	}
	root, _ = realpath(env.absPath(pyNorm(root)), false, env.Cwd)
	argv, err := safeArgv(d["argv"])
	if err != nil {
		return nil, err
	}
	environment, err := sanitizeEnvironment(d["environment"])
	if err != nil {
		return nil, err
	}
	inputSpec, err := keysOf(d["input"], []string{"path", "detected_type"}, "input spec")
	if err != nil {
		return nil, err
	}
	input, _, err := artifactIdentity(root, inputSpec["path"], "input.path", false, env)
	if err != nil {
		return nil, err
	}
	input["name"] = pyName(input["path"].(string))
	input["detected_type"] = inputSpec["detected_type"]
	if input["detected_type"] != nil {
		if _, err := textOf(input["detected_type"], "input.detected_type"); err != nil {
			return nil, err
		}
	}

	toolSpec, err := keysOf(d["tool"], []string{"name", "version", "executable", "artifacts"}, "tool spec")
	if err != nil {
		return nil, err
	}
	artifactList, ok := toolSpec["artifacts"].([]any)
	if !ok {
		return nil, mfail("tool.artifacts must be an array")
	}
	toolArtifacts := make([]obj, len(argv))
	seen := map[int]bool{}
	for index, value := range artifactList {
		item, err := keysOf(value, []string{"path", "argv_index"}, fmt.Sprintf("tool.artifacts[%d]", index))
		if err != nil {
			return nil, err
		}
		path, err := analysisArtifactPath(item["path"], "analysis artifact path")
		if err != nil {
			return nil, err
		}
		argvIndex, err := boundArgvIndex(item["argv_index"], argv, path, seen)
		if err != nil {
			return nil, err
		}
		rec, _, err := artifactIdentity(root, path, fmt.Sprintf("tool.artifacts[%d].path", index), true, env)
		if err != nil {
			return nil, err
		}
		rec["argv_index"] = num(int64(argvIndex))
		toolArtifacts[argvIndex] = rec // argv_index is unique and below len(argv), so this is the sorted order
	}
	name, err := textOf(toolSpec["name"], "tool.name")
	if err != nil {
		return nil, err
	}
	version, err := textOf(toolSpec["version"], "tool.version")
	if err != nil {
		return nil, err
	}
	executable, err := textOf(toolSpec["executable"], "tool.executable")
	if err != nil {
		return nil, err
	}
	launcher, err := resolveTool(argv[0], executable, root, environment, env)
	if err != nil {
		return nil, err
	}
	artifacts := []any{}
	for _, a := range toolArtifacts {
		if a != nil {
			artifacts = append(artifacts, a)
		}
	}

	outputList, ok := d["outputs"].([]any)
	if !ok {
		return nil, mfail("outputs must be an array")
	}
	outputs := make([]any, 0, len(outputList))
	for index, item := range outputList {
		rec, _, err := artifactIdentity(root, item, fmt.Sprintf("outputs[%d]", index), false, env)
		if err != nil {
			return nil, err
		}
		outputs = append(outputs, rec)
	}
	findings, ok := d["findings"].([]any)
	if !ok {
		return nil, mfail("findings must be an array")
	}
	for index, f := range findings {
		fd, err := keysOf(f, []string{"id", "claim", "evidence_locations"}, fmt.Sprintf("findings[%d]", index))
		if err != nil {
			return nil, err
		}
		for _, field := range [][2]string{{"id", "finding.id"}, {"claim", "finding.claim"}} {
			if _, err := textOf(fd[field[0]], field[1]); err != nil {
				return nil, err
			}
		}
		if locs, ok := fd["evidence_locations"].([]any); !ok || len(locs) == 0 {
			return nil, mfail("finding evidence_locations must be a non-empty array")
		}
	}
	stdout, _, err := artifactIdentity(root, d["stdout_path"], "stdout_path", false, env)
	if err != nil {
		return nil, err
	}
	stderr, _, err := artifactIdentity(root, d["stderr_path"], "stderr_path", false, env)
	if err != nil {
		return nil, err
	}
	slices.SortStableFunc(outputs, func(a, b any) int { return strings.Compare(a.(obj)["path"].(string), b.(obj)["path"].(string)) })
	sorted := slices.Clone(findings)
	slices.SortStableFunc(sorted, func(a, b any) int { return strings.Compare(a.(obj)["id"].(string), b.(obj)["id"].(string)) })
	argvList := make([]any, len(argv))
	for i, a := range argv {
		argvList[i] = a
	}
	envObj := obj{}
	for k, v := range environment {
		envObj[k] = v
	}
	m := obj{
		"schema_version": SchemaVersion, "identity": "", "input": input,
		"tool": obj{"name": name, "version": version, "launcher": launcher, "artifacts": artifacts},
		"argv": argvList, "environment": envObj, "run": d["run"], "stdout": stdout, "stderr": stderr,
		"outputs": outputs, "findings": sorted, "limitations": d["limitations"], "errors": d["errors"],
		"completeness": d["completeness"], "isolation_profile": d["isolation_profile"],
	}
	if m["identity"], err = manifestIdentity(m); err != nil {
		return nil, err
	}
	if err := ValidateManifest(m, env); err != nil {
		return nil, err
	}
	return m, nil
}

// runTime is datetime.fromisoformat for the timestamps a manifest records: RFC 3339 with the "Z" the
// document must end in. Other ISO 8601 spellings Python accepts (no seconds, week dates, a space for
// the "T", hour 24) are rejected here.
func runTime(v any, field string) (time.Time, error) {
	s, ok := v.(string)
	if !ok || !strings.HasSuffix(s, "Z") {
		return time.Time{}, mfail("run." + field + " must be UTC ISO-8601")
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}, mfail("run." + field + " is not a valid ISO-8601 timestamp")
	}
	return t, nil
}

func isBool(v any) bool { _, ok := v.(bool); return ok }

// ValidateManifest is validate_manifest: the document alone, nothing on disk.
func ValidateManifest(manifest any, env Env) error {
	top, err := keysOf(manifest, []string{"schema_version", "identity", "input", "tool", "argv", "environment", "run", "stdout", "stderr", "outputs", "findings", "limitations", "errors", "completeness", "isolation_profile"}, "manifest")
	if err != nil {
		return err
	}
	if sv, ok := top["schema_version"].(string); !ok || sv != SchemaVersion {
		return mfail("unknown schema version: " + reprValue(top["schema_version"]))
	}
	if id, ok := top["identity"].(string); !ok || !hashRE.MatchString(id) {
		return mfail("identity is not a SHA-256 identity")
	}
	inp, err := keysOf(top["input"], []string{"path", "name", "size", "sha256", "detected_type"}, "input")
	if err != nil {
		return err
	}
	argv, err := safeArgv(top["argv"])
	if err != nil {
		return err
	}
	tool, err := keysOf(top["tool"], []string{"name", "version", "launcher", "artifacts"}, "tool")
	if err != nil {
		return err
	}
	launcher, err := keysOf(tool["launcher"], []string{"resolved_executable", "sha256"}, "tool.launcher")
	if err != nil {
		return err
	}
	artifacts := []obj{inp}
	for _, f := range []string{"stdout", "stderr"} {
		d, err := keysOf(top[f], []string{"path", "size", "sha256"}, f)
		if err != nil {
			return err
		}
		artifacts = append(artifacts, d)
	}
	outputs, ok := top["outputs"].([]any)
	if !ok {
		return mfail("outputs must be an array")
	}
	for _, item := range outputs {
		d, err := keysOf(item, []string{"path", "size", "sha256"}, "output")
		if err != nil {
			return err
		}
		artifacts = append(artifacts, d)
	}
	toolArtifacts, ok := tool["artifacts"].([]any)
	if !ok {
		return mfail("tool.artifacts must be an array")
	}
	seen := map[int]bool{}
	var analysis []obj
	for _, item := range toolArtifacts {
		rec, err := keysOf(item, []string{"path", "size", "sha256", "argv_index"}, "tool artifact")
		if err != nil {
			return err
		}
		path, err := analysisArtifactPath(rec["path"], "analysis artifact path")
		if err != nil {
			return err
		}
		if _, err := boundArgvIndex(rec["argv_index"], argv, path, seen); err != nil {
			return err
		}
		analysis = append(analysis, rec)
	}
	for _, item := range artifacts {
		if _, err := relativePath(item["path"], "artifact.path"); err != nil {
			return err
		}
	}
	for _, item := range append(append([]obj(nil), artifacts...), analysis...) {
		sha, shaOK := item["sha256"].(string)
		if !isNonNegInt(item["size"]) || !shaOK || !hashRE.MatchString(sha) {
			return mfail("artifact size or SHA-256 is invalid")
		}
	}
	artifacts = append(artifacts, analysis...)
	if name, ok := inp["name"].(string); !ok || name != pyName(inp["path"].(string)) {
		return mfail("input name or detected_type is invalid")
	}
	if detected := inp["detected_type"]; detected != nil {
		if s, ok := detected.(string); !ok || strings.TrimFunc(s, pySpace) == "" {
			return mfail("input name or detected_type is invalid")
		}
	}
	for _, f := range []string{"name", "version"} {
		if _, err := textOf(tool[f], "tool."+f); err != nil {
			return err
		}
	}
	executable, err := textOf(launcher["resolved_executable"], "tool.launcher.resolved_executable")
	if err != nil {
		return err
	}
	if !strings.HasPrefix(executable, "/") {
		if _, err := relativePath(executable, "tool.launcher.resolved_executable"); err != nil {
			return err
		}
	}
	if argv0 := argv[0]; strings.ContainsAny(argv0, "/\\") {
		if executable != argv0 {
			return mfail("tool launcher is not coherent with argv zero")
		}
	} else {
		environment, _ := top["environment"].(obj)
		pathValue, _ := environment["PATH"].(string)
		found := false
		for _, d := range pathDirsOf(pathValue, env) {
			found = found || d == pyParent(executable)
		}
		if !strings.HasPrefix(executable, "/") || pyName(executable) != argv0 || !found {
			return mfail("PATH launcher is not coherent with argv zero")
		}
	}
	if sha, ok := launcher["sha256"].(string); !ok || !hashRE.MatchString(sha) {
		return mfail("tool SHA-256 is invalid")
	}
	if _, err := sanitizeEnvironment(top["environment"]); err != nil {
		return err
	}
	run, err := keysOf(top["run"], []string{"started_at", "ended_at", "duration_ms", "exit_code", "signal"}, "run")
	if err != nil {
		return err
	}
	started, err := runTime(run["started_at"], "started_at")
	if err != nil {
		return err
	}
	ended, err := runTime(run["ended_at"], "ended_at")
	if err != nil {
		return err
	}
	if ended.Before(started) {
		return mfail("run.ended_at precedes run.started_at")
	}
	if !isNonNegInt(run["duration_ms"]) {
		return mfail("run.duration_ms is invalid")
	}
	exit, signal := run["exit_code"], run["signal"]
	if (exit == nil) == (signal == nil) || (exit != nil && !isNonNegInt(exit)) || (signal != nil && !isNonNegInt(signal)) {
		return mfail("run requires exactly one non-negative exit_code or signal")
	}
	known := map[string]bool{}
	for _, a := range artifacts {
		known[a["path"].(string)] = true
	}
	findings, ok := top["findings"].([]any)
	if !ok {
		return mfail("findings must be an array")
	}
	ids := map[string]bool{}
	for _, f := range findings {
		fd, err := keysOf(f, []string{"id", "claim", "evidence_locations"}, "finding")
		if err != nil {
			return err
		}
		id, err := textOf(fd["id"], "finding.id")
		if err != nil {
			return err
		}
		if _, err := textOf(fd["claim"], "finding.claim"); err != nil {
			return err
		}
		if ids[id] {
			return mfail("finding IDs must be unique")
		}
		ids[id] = true
		locs, ok := fd["evidence_locations"].([]any)
		if !ok || len(locs) == 0 {
			return mfail("finding evidence_locations is invalid")
		}
		for _, loc := range locs {
			path, start, end, err := evidenceLocation(loc)
			if err != nil {
				return err
			}
			if !known[path] || end.Cmp(start) < 0 {
				return mfail("finding evidence location is invalid or unbound")
			}
		}
	}
	for _, f := range []string{"limitations", "errors"} {
		list, ok := top[f].([]any)
		for _, item := range list {
			if s, isStr := item.(string); !isStr || strings.TrimFunc(s, pySpace) == "" {
				ok = false
			}
		}
		if !ok {
			return mfail(f + " must be a string array")
		}
	}
	if c, ok := top["completeness"].(string); !ok || (c != "complete" && c != "partial" && c != "failed") {
		return mfail("completeness is invalid")
	}
	iso, err := keysOf(top["isolation_profile"], []string{"name", "static_only", "network_access", "target_execution"}, "isolation_profile")
	if err != nil {
		return err
	}
	if _, err := textOf(iso["name"], "isolation_profile.name"); err != nil {
		return err
	}
	if !isBool(iso["static_only"]) || !isBool(iso["network_access"]) || iso["target_execution"] != false {
		return mfail("isolation profile must record target_execution=false")
	}
	want, err := manifestIdentity(top)
	if err != nil {
		return err
	}
	if top["identity"].(string) != want {
		return mfail("manifest identity does not match canonical stable content")
	}
	return nil
}

// pathDirsOf is the absolute directories of a PATH value, each resolved like Path.resolve().
func pathDirsOf(pathValue string, env Env) []string {
	var dirs []string
	for _, item := range strings.Split(pathValue, ":") {
		if strings.HasPrefix(item, "/") {
			r, _ := realpath(pyNorm(item), false, env.Cwd)
			dirs = append(dirs, r)
		}
	}
	return dirs
}

// VerifyArtifacts is verify_artifacts: rehash every recorded file without launching anything.
func VerifyArtifacts(manifest any, root string, env Env) error {
	if err := ValidateManifest(manifest, env); err != nil {
		return err
	}
	m := manifest.(obj)
	root, _ = realpath(env.absPath(pyNorm(root)), false, env.Cwd)
	var records []obj
	for _, k := range []string{"input", "stdout", "stderr"} {
		records = append(records, m[k].(obj))
	}
	for _, o := range m["outputs"].([]any) {
		records = append(records, o.(obj))
	}
	tool := m["tool"].(obj)
	firstTool := len(records)
	for _, a := range tool["artifacts"].([]any) {
		records = append(records, a.(obj))
	}
	lines := map[string]int64{}
	for index, r := range records {
		current, n, err := artifactIdentity(root, r["path"], fmt.Sprintf("recorded artifact[%d]", index), index >= firstTool, env)
		if err != nil {
			return err
		}
		size, _ := asInt(r["size"])
		curSize, _ := asInt(current["size"])
		if current["path"] != r["path"] || current["sha256"] != r["sha256"] || curSize.Cmp(size) != 0 {
			return mfail(fmt.Sprintf("recorded artifact[%d] identity changed", index))
		}
		lines[r["path"].(string)] = n
	}
	launcher := tool["launcher"].(obj)
	environment := map[string]string{}
	for k, v := range m["environment"].(obj) {
		environment[k] = v.(string)
	}
	current, err := resolveTool(m["argv"].([]any)[0].(string), launcher["resolved_executable"].(string), root, environment, env)
	if err != nil {
		return err
	}
	if current["resolved_executable"] != launcher["resolved_executable"] || current["sha256"] != launcher["sha256"] {
		return mfail("file-backed tool identity changed")
	}
	for _, f := range m["findings"].([]any) {
		for _, loc := range f.(obj)["evidence_locations"].([]any) {
			path, _, end, _ := evidenceLocation(loc)
			if end.Cmp(big.NewInt(lines[path])) > 0 {
				return mfail("finding evidence location exceeds file line count")
			}
		}
	}
	return nil
}
