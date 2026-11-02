package adapter

import "os"

// CurrentCreds reads the process ids.
func CurrentCreds() Creds {
	return Creds{UID: os.Getuid(), EUID: os.Geteuid(), GID: os.Getgid(), EGID: os.Getegid()}
}

// RefusePrivilegedExecution is adapter_core.refuse_privileged_execution:
// root, or a real id that differs from the effective one (set-id execution),
// is refused with the exact message the inline guards used.
func RefusePrivilegedExecution(c Creds) error {
	if c.EUID == 0 || c.UID != c.EUID || c.GID != c.EGID {
		return &Error{Msg: "refusing root or set-id execution"}
	}
	return nil
}
