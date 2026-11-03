package migratebacklogs

import "io"

// RED stub: the unported command.
type Options struct {
	Args     []string
	Out, Err io.Writer
	FS       interface{}
}

func Run(o Options) int { return 99 }
