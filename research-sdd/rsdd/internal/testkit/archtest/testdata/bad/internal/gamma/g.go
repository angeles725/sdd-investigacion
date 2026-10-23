package gamma

import (
	"os"
	stdtime "time"
)

var _ = os.Getenv("X")
var _ = os.LookupEnv
var _ = stdtime.Now()
var _, _ = os.Getwd()
