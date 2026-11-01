//go:build !linux

package serial

import "errors"

// openSerialPort: the termios driver is Linux-only; elsewhere the port is reported unavailable (the legacy
// script needed pyserial and a Python interpreter).
func openSerialPort(path string, baud int64) (serialPort, error) {
	return nil, errors.New("serial ports are only supported on Linux")
}
