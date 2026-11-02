//go:build !unix

package adapter

import "syscall"

func statFD(int) (statTuple, error)            { return statTuple{}, syscall.ENOSYS }
func statSys(string) (statTuple, error)        { return statTuple{}, syscall.ENOSYS }
func openNoFollow(string) (int, error)         { return -1, syscall.ENOSYS }
func readFD(int, []byte) (int, error)          { return 0, syscall.ENOSYS }
func closeFD(int) error                        { return syscall.ENOSYS }
func createExcl(string) (int, error)           { return -1, syscall.ENOSYS }
func writeAll(int, []byte) error               { return syscall.ENOSYS }
func syncFD(int) error                         { return syscall.ENOSYS }
func renameFile(oldPath, newPath string) error { return syscall.ENOSYS }
