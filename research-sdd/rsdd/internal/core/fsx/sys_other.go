//go:build !linux

package fsx

import "errors"

// errNoSys is the cause reported by every OS-bound primitive off Linux.
var errNoSys = &Error{Kind: ErrUnavailable, Err: errors.New("filesystem primitives require Linux")}

func sysOpenRO(string) (int, error)          { return -1, errNoSys }
func sysOpenWONew(string) (int, error)       { return -1, errNoSys }
func sysFstat(int) (Stat, error)             { return Stat{}, errNoSys }
func sysRead(int, []byte) (int, error)       { return 0, errNoSys }
func sysClose(int) error                     { return errNoSys }
func sysSeekStart(int) error                 { return errNoSys }
func sysResolveFD(_ int, path string) string { return path }

func sysWrite(int, []byte) (int, error)                 { return 0, errNoSys }
func sysFsync(int) error                                { return errNoSys }
func sysOpenDir(string) (int, error)                    { return -1, errNoSys }
func sysRenameat2(int, string, int, string, uint) error { return errNoSys }
