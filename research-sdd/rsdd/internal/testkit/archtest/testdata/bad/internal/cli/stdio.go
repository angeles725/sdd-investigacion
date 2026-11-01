package cli

import (
	"os"
	"path/filepath"
	"time"
)

var _ = os.Getenv("OK")
var _ = time.Now
var _, _ = os.Getwd()
var _, _ = filepath.Abs("exempt")
