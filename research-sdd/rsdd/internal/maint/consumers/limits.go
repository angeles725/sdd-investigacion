package consumers

// limits are the things this command cannot see (issue #2758, "the output states its limits on every run"), one
// line each, in the order they are printed.
var limits = []string{
	"names that arrive through a flag or an environment variable are not seen",
	"names built at run time are not seen",
	"globs are not expanded: a pattern that matches a script is not a reference to it",
	"names without the extension are not matched",
	"nothing outside the repository is read: other repositories, installed copies, harness homes, git history",
	"a match is a whole-name occurrence in text, not proof of a call: prose and comments count",
}
