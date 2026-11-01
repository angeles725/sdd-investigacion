package commands

import (
	_ "example.test/m/internal/alpha"
	"os"
)

// The registry tier may import any domain but is still subject to the call ban.
var _ = os.Getenv("REGISTRY_IS_NOT_EXEMPT")
