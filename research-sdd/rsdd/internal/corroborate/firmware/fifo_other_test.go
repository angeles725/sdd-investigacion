//go:build !linux && !darwin

package firmware

import "errors"

func mkfifo(string) error { return errors.New("no named pipes on this platform") }
