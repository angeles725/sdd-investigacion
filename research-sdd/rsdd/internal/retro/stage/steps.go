package stage

import "strings"

// quoteIn escapes s for a word that the printed command wraps in single quotes (POSIX: the quote ends, is escaped, reopens): the retro's file name and the
// target label end up inside '...', and a quote in either ended the quoting early.
func quoteIn(s string) string { return strings.ReplaceAll(s, "'", `'\''`) }

// nextSteps prints the supervisor's checklist. The commands are suggestions: the port, like the script,
// commits, pushes and opens nothing.
func (s *stager) nextSteps(retroRef string) {
	kit, label, slug, branch := s.o.KitRoot, quoteIn(s.label), quoteIn(s.slug), s.branch
	s.outf(">> NEXT STEPS (supervisor):\n")
	s.outf("   1. Apply the ACCEPTED deltas to the kit files on THIS branch (skip duplicates/unneeded ones).\n")
	s.outf("   2. git -C \"%s\" add -A && git -C \"%s\" commit -m 'feat(kit): apply retro deltas from %s (%s)' -m 'Retro: %s'\n", kit, kit, label, slug, quoteIn(retroRef))
	s.outf("   3. VALIDATE BEFORE MERGE (mandatory — the applier must NOT self-approve): launch an INDEPENDENT\n")
	s.outf("      fresh-context reviewer over the applied deltas. It verifies each as FAITHFUL / DRIFT /\n")
	s.outf("      HALLUCINATION / MISSING / DUPLICATE against this retro's proposed-deltas table + current kit\n")
	s.outf("      state. Fix any DRIFT/hallucination on the branch first; only a clean review earns the merge.\n")
	s.outf("   4. gh -R \"$(git -C \"%s\" remote get-url origin)\" pr create --fill --base main --head %s \\\n", kit, branch)
	s.outf("        --title 'retro: %s %s' --body-file \"%s\"\n", label, slug, s.retro)
	s.outf("   5. Review the PR (conflicts vs main, dup vs other open retro PRs, necessity). Merge = applied, close = dismissed.\n")
	s.outf("   6. Mark the source retro: set '<!-- review-status: applied <date> · kit <sha> -->' (or dismissed) at its top.\n")
	s.outf("   7. Clean up the staging branch and the review transaction:\n")
	s.outf("      After the PR is merged or closed:\n")
	s.outf("        git -C \"$KIT_REPO\" branch -d %s\n", branch)
	s.outf("        git push origin --delete %s   (if the remote branch still exists)\n", branch)
	s.outf("      If 'gentle-ai review status' returns 'lineage_selection_required', run it first to\n")
	s.outf("      pick the right lineage, then validate: gentle-ai review validate --gate pre-commit\n")
	s.outf("      --cwd \"$KIT_REPO\". Stale .git/gentle-ai/review-transactions/v2/<lineage>/ dirs can\n")
	s.outf("      be archived once their PR is closed — 36 accumulated because this step was missing.\n")
}
