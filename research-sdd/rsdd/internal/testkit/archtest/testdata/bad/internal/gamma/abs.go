package gamma

import "path/filepath"

// filepath.Abs on a relative path reads the process cwd implicitly.
var _, _ = filepath.Abs("rel")
