package consumers

// options is what the command line said.
type options struct {
	repo   string
	script string // restrict to this basename ("" for all live scripts)
	refs   bool
	help   bool
}

// parse reads the command line; a non-empty second result is the usage error.
func parse(args []string) (options, string) {
	var o options
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-h" || a == "--help" {
			o.help = true
			return o, ""
		}
		if a == "--repo" {
			if i+1 >= len(args) || args[i+1] == "" {
				return o, "--repo needs a value"
			}
			i++
			o.repo = args[i]
			continue
		}
		if a == "--refs" {
			o.refs = true
			continue
		}
		if a == "--script" {
			if i+1 >= len(args) || args[i+1] == "" {
				return o, "--script needs a value"
			}
			i++
			o.script = args[i]
			continue
		}
		return o, "unknown argument: " + a
	}
	return o, ""
}
