//go:build linux

package serial

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"
)

// The Linux serial port: open the tty without becoming its controlling terminal, put it in raw 8N1 mode with no
// flow control, set the baud rate and read with pyserial's timeout semantics. This is the configuration
// pyserial applied for the legacy script (timeout set, rtscts and dsrdtr off, xonxoff off).

// standardBauds maps a rate to its termios speed constant (pyserial's table for Linux).
var standardBauds = map[int64]uint32{
	0: syscall.B0, 50: syscall.B50, 75: syscall.B75, 110: syscall.B110, 134: syscall.B134, 150: syscall.B150,
	200: syscall.B200, 300: syscall.B300, 600: syscall.B600, 1200: syscall.B1200, 1800: syscall.B1800,
	2400: syscall.B2400, 4800: syscall.B4800, 9600: syscall.B9600, 19200: syscall.B19200, 38400: syscall.B38400,
	57600: syscall.B57600, 115200: syscall.B115200, 230400: syscall.B230400, 460800: syscall.B460800,
	500000: syscall.B500000, 576000: syscall.B576000, 921600: syscall.B921600, 1000000: syscall.B1000000,
	1152000: syscall.B1152000, 1500000: syscall.B1500000, 2000000: syscall.B2000000, 2500000: syscall.B2500000,
	3000000: syscall.B3000000, 3500000: syscall.B3500000, 4000000: syscall.B4000000,
}

// Constants of the generic Linux termios2 ABI (x86, arm, arm64, riscv): a non-standard rate goes through
// TCSETS2 with BOTHER.
const (
	tcgets2 = 0x802c542a
	tcsets2 = 0x402c542b
	tcflsh  = 0x540b
	bother  = 0o010000
	cbaud   = 0o010017
	tciflsh = 0
)

const crtscts = 0o20000000000

type termios2 struct {
	Iflag, Oflag, Cflag, Lflag uint32
	Line                       uint8
	Cc                         [19]uint8
	Ispeed, Ospeed             uint32
}

func ioctl(fd int, req uintptr, arg unsafe.Pointer) error {
	if _, _, en := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, uintptr(arg)); en != 0 {
		return en
	}
	return nil
}

// portError is a pyserial-worded failure text (kept verbatim, capitalised as pyserial words it).
type portError string

func (e portError) Error() string { return string(e) }

type ttyPort struct {
	f   *os.File
	now func() time.Time // the command's clock
}

// openSerialPort opens path read-write (O_NOCTTY|O_NONBLOCK, as pyserial does) and configures it raw 8N1 at
// baud. Failures read like pyserial's SerialException texts.
func openSerialPort(path string, baud int64, now func() time.Time) (serialPort, error) {
	if baud < 0 {
		return nil, portError(fmt.Sprintf("Not a valid baudrate: %d", baud))
	}
	fd, err := syscall.Open(path, syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		en, _ := errnoOf(err)
		return nil, fmt.Errorf("[Errno %d] could not open port %s: %s", int(en), path, osErrorText(en, path))
	}
	if err := configureRaw(fd, baud); err != nil {
		_ = syscall.Close(fd)
		return nil, err
	}
	return &ttyPort{f: os.NewFile(uintptr(fd), path), now: now}, nil
}

// configureRaw is pyserial's _reconfigure_port for 8 data bits, no parity, one stop bit, no flow control.
func configureRaw(fd int, baud int64) error {
	var t syscall.Termios
	if err := ioctl(fd, syscall.TCGETS, unsafe.Pointer(&t)); err != nil {
		return termiosError(err)
	}
	t.Cflag |= syscall.CLOCAL | syscall.CREAD
	t.Lflag &^= syscall.ICANON | syscall.ECHO | syscall.ECHOE | syscall.ECHOK | syscall.ECHONL | syscall.ISIG | syscall.IEXTEN | syscall.ECHOCTL | syscall.ECHOKE
	t.Oflag &^= syscall.OPOST | syscall.ONLCR | syscall.OCRNL
	t.Iflag &^= syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IGNBRK | syscall.PARMRK | syscall.INPCK | syscall.ISTRIP | syscall.IXON | syscall.IXOFF | syscall.IXANY
	t.Cflag &^= syscall.CSIZE | syscall.CSTOPB | syscall.PARENB | syscall.PARODD | crtscts
	t.Cflag |= syscall.CS8
	t.Cc[syscall.VMIN], t.Cc[syscall.VTIME] = 0, 0 // the timeout is enforced by the read deadline
	if speed, ok := standardBauds[baud]; ok {
		t.Cflag = t.Cflag&^cbaud | speed
		if err := ioctl(fd, syscall.TCSETS, unsafe.Pointer(&t)); err != nil {
			return termiosError(err)
		}
	} else if err := setCustomBaud(fd, &t, baud); err != nil {
		return termiosError(err)
	}
	// pyserial discards pending input on open; a device that refuses the flush (ENOTTY, EINVAL) is tolerated
	if _, _, en := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), tcflsh, tciflsh); en != 0 && en != syscall.ENOTTY && en != syscall.EINVAL {
		return termiosError(en)
	}
	return nil
}

// setCustomBaud applies t with an arbitrary rate through termios2.
func setCustomBaud(fd int, t *syscall.Termios, baud int64) error {
	if baud > 0xffffffff {
		return syscall.EINVAL
	}
	var t2 termios2
	if err := ioctl(fd, tcgets2, unsafe.Pointer(&t2)); err != nil {
		return err
	}
	t2.Iflag, t2.Oflag, t2.Lflag, t2.Line = t.Iflag, t.Oflag, t.Lflag, t.Line
	copy(t2.Cc[:], t.Cc[:])
	t2.Cflag = t.Cflag&^cbaud | bother
	t2.Ispeed, t2.Ospeed = uint32(baud), uint32(baud)
	return ioctl(fd, tcsets2, unsafe.Pointer(&t2))
}

// termiosError words a failed termios call like pyserial: "Could not configure port: (25, 'Inappropriate ioctl
// for device')".
func termiosError(err error) error {
	en, _ := errnoOf(err)
	return portError(fmt.Sprintf("Could not configure port: (%d, %s)", int(en), pyRepr(strerror(en))))
}

// Read collects up to n bytes, returning when n bytes arrived or timeout has elapsed in total. Like pyserial it
// waits for readiness first (the descriptor is non-blocking and VMIN is 0, so a bare read would return at once).
func (p *ttyPort) Read(n int, timeout time.Duration) ([]byte, error) {
	deadline := p.now().Add(timeout)
	rc, err := p.f.SyscallConn()
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, n)
	buf := make([]byte, n)
	for len(out) < n {
		if err := p.f.SetReadDeadline(deadline); err != nil {
			return out, err
		}
		var got int
		var rerr error
		calls := 0
		err := rc.Read(func(fd uintptr) bool {
			calls++
			for {
				got, rerr = syscall.Read(int(fd), buf[:n-len(out)])
				if rerr != syscall.EINTR {
					break
				}
			}
			// The first call is made before any readiness wait: an empty read there only means "no data yet".
			return rerr != syscall.EAGAIN && (got > 0 || rerr != nil || calls > 1)
		})
		switch {
		case errors.Is(err, os.ErrDeadlineExceeded):
			return out, nil
		case err != nil:
			return out, fmt.Errorf("read failed: %w", err)
		case rerr != nil:
			en, _ := errnoOf(rerr)
			return out, fmt.Errorf("read failed: %s", osErrorText(en, ""))
		case got == 0:
			return out, errors.New("device reports readiness to read but returned no data (device disconnected or multiple access on port?)")
		}
		out = append(out, buf[:got]...)
		if !p.now().Before(deadline) {
			break
		}
	}
	return out, nil
}

func (p *ttyPort) Close() error { return p.f.Close() }
