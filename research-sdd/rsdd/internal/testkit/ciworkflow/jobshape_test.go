package ciworkflow

import (
	"strings"
)

// checkJobShape judges one workflow source against the shape the merge gate and the join depend on, and returns
// one finding per problem (none for a conforming source). It is pure: the real file is read by the caller.
//
//   - toolbelt-tests: the JOIN. No `name:` (the check name is the job id), an `if:` with always() so a failed shard
//     is a red join and not a skipped one, `needs` naming every shard job, and a body that reads
//     needs.<id>.result of each of them (the step that turns a cancelled shard red).
//   - a shard job is a matrix job (the join expects its manifests), has no `${{` in its name (the merge gate's
//     parser treats it as unparseable) and uploads its manifest in a step that runs `if: always()` and fails on
//     `if-no-files-found: error`.
//   - shellcheck: a required check, so it exists and no job-level `if:` can skip it.
//
// A source with no readable jobs, no join or no shard job is a finding, never a pass.
func checkJobShape(src string) []string {
	jobs, st := Jobs(src)
	if st != Found {
		return []string{"jobs: " + st.String()}
	}
	byID := map[string]Job{}
	for _, j := range jobs {
		byID[j.ID] = j
	}
	var out []string
	join, ok := byID["toolbelt-tests"]
	if !ok {
		out = append(out, "toolbelt-tests: no such job")
	} else {
		out = append(out, checkJoin(join, byID)...)
	}
	shards := 0
	for _, j := range jobs {
		if j.Matrix {
			shards++
			out = append(out, checkShard(j, ok && contains(join.Needs, j.ID))...)
		}
	}
	if shards == 0 {
		out = append(out, "no shard job: no job has a strategy matrix")
	}
	if sc, ok := byID["shellcheck"]; !ok {
		out = append(out, "shellcheck: no such job")
	} else if sc.If != "" {
		out = append(out, "shellcheck: has the job-level if: "+sc.If)
	}
	return out
}

func checkJoin(join Job, byID map[string]Job) []string {
	var out []string
	if join.Name != "" {
		out = append(out, "toolbelt-tests: has the name: "+join.Name)
	}
	if !strings.Contains(join.If, "always()") {
		out = append(out, "toolbelt-tests: if: is "+quoteOrNone(join.If)+", want it to contain always()")
	}
	if len(join.Needs) == 0 {
		out = append(out, "toolbelt-tests: needs names no job")
	}
	body := strings.Join(join.Body, "\n")
	for _, n := range join.Needs {
		if nj, ok := byID[n]; !ok {
			out = append(out, "toolbelt-tests: needs "+n+", which is not a job")
		} else if !nj.Matrix {
			out = append(out, n+": a shard job named in needs is not a matrix job")
		}
		if !strings.Contains(body, "needs."+n+".result") {
			out = append(out, "toolbelt-tests: never reads needs."+n+".result")
		}
	}
	return out
}

func checkShard(j Job, needed bool) []string {
	var out []string
	if !needed {
		out = append(out, j.ID+": is a matrix job that toolbelt-tests does not need")
	}
	if strings.Contains(j.Name, "${{") {
		out = append(out, j.ID+": name contains ${{")
	}
	up := uploadStep(j.Body)
	if up == nil {
		return append(out, j.ID+": no actions/upload-artifact step")
	}
	if !contains(up, "if: always()") {
		out = append(out, j.ID+": the upload step lacks if: always()")
	}
	if !contains(up, "if-no-files-found: error") {
		out = append(out, j.ID+": the upload step lacks if-no-files-found: error")
	}
	return out
}

// uploadStep returns the trimmed lines of the first step that uses actions/upload-artifact, nil when there is none.
func uploadStep(body []string) []string {
	var steps [][]string
	itemIndent := -1
	inSteps := false
	for _, l := range body {
		t := strings.TrimSpace(l)
		if t == "steps:" {
			inSteps = true
			continue
		}
		if inSteps && strings.HasPrefix(t, "- ") && (itemIndent < 0 || indent(l) == itemIndent) {
			itemIndent = indent(l)
			steps = append(steps, []string{strings.TrimPrefix(t, "- ")})
			continue
		}
		if inSteps && len(steps) > 0 {
			steps[len(steps)-1] = append(steps[len(steps)-1], t)
		}
	}
	for _, s := range steps {
		for _, l := range s {
			if strings.HasPrefix(l, "uses: actions/upload-artifact") {
				return s
			}
		}
	}
	return nil
}

func contains(list []string, want string) bool {
	for _, l := range list {
		if l == want {
			return true
		}
	}
	return false
}

func quoteOrNone(s string) string {
	if s == "" {
		return "absent"
	}
	return `"` + s + `"`
}
