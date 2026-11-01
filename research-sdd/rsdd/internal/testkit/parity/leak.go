package parity

import (
	"crypto/rand"
	"encoding/hex"
)

// runMarkerEnv names the environment variable that tags every process a case
// starts. Both sides of a case get the same random value (so their outputs stay
// comparable); a process that carries it after its side has ended escaped the
// process group (setsid) and is reaped and reported as "leaked-process".
const runMarkerEnv = "RSDD_PARITY_RUN"

func newNonce() (string, error) {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
