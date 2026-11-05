package writercheck

// options is what the command line said.
type options struct {
	base, head   string
	headGiven    bool
	worktree     bool
	logDir       string
	format       string // "report" or "json"
	repo         string
	manifestDir  string
	tolerate     bool
	printBinding bool
	classify     bool
	write        bool
	writeDir     string
	positional   []string // suites (write mode) or paths (classify)
}

// failure is a refused command line: the optional message line (printed with the `kit-writer-check: ` prefix) and
// the usage text that follows it.
type failure struct{ msg string }

// parse is the argument loop of the bash tool: a flag that needs a value and has none, -h/--help, and an unknown
// flag all end in the usage text (exit 2); anything else that is not a flag is positional. The checks that need the
// repository (and so come later) are in modes.go.
func parse(args []string) (options, *failure) {
	o := options{head: "HEAD", format: "report", repo: "."}
	value := func(i *int) (string, bool) {
		if *i+1 >= len(args) {
			return "", false
		}
		*i++
		return args[*i], true
	}
	for i := 0; i < len(args); i++ {
		var ok bool
		switch a := args[i]; a {
		case "--base":
			o.base, ok = value(&i)
		case "--head":
			o.head, ok = value(&i)
			o.headGiven = ok
		case "--worktree":
			o.worktree, ok = true, true
		case "--teeth-log":
			o.logDir, ok = value(&i)
		case "--format":
			o.format, ok = value(&i)
		case "--repo":
			o.repo, ok = value(&i)
		case "--manifest-dir":
			o.manifestDir, ok = value(&i)
		case "--tolerate-stale-manifest":
			o.tolerate, ok = true, true
		case "--print-binding":
			o.printBinding, ok = true, true
		case "--classify":
			o.classify, ok = true, true
		case "--write-teeth-log":
			o.writeDir, ok = value(&i)
			o.write = ok
		case "-h", "--help":
			return o, &failure{}
		default:
			if len(a) > 0 && a[0] == '-' {
				return o, &failure{msg: "unknown argument: " + a}
			}
			o.positional, ok = append(o.positional, a), true
		}
		if !ok {
			return o, &failure{}
		}
	}
	return o, nil
}
