package goimpact

// exactFull are the module files whose change affects every command, with the FULL reason.
var exactFull = map[string]string{
	"go.mod":         "go.mod changes the whole build",
	"go.sum":         "go.sum changes the whole build",
	"teeth-debt.txt": "teeth-debt.txt is read by the Go bridge suite",
	"Makefile":       "Makefile changes how the binary is built",
}

// prefixFull are the module directories whose change affects every command, with the FULL reason.
var prefixFull = []struct{ prefix, why string }{
	{"cmd/", "cmd/** is the binary entry point"},
	{"internal/cli/", "internal/cli/** is the dispatcher every command runs through"},
	{"internal/commands/", "internal/commands/** is the command registry"},
}
