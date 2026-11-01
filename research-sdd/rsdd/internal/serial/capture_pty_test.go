//go:build linux

package serial

// The real termios path, driven through a pseudo-terminal (never a real device): the port is configured raw
// 8N1 at the requested rate, bytes written to the master side arrive as frames, and the open/configure failures
// read like pyserial's.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// openPTY returns the master side and the path of the slave side of a new pseudo-terminal.
func openPTY(t *testing.T) (master *os.File, slave string) {
	t.Helper()
	m, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("no pseudo-terminal available: %v", err)
	}
	var unlock int32
	var num uint32
	if err := ioctl(int(m.Fd()), 0x40045431, unsafe.Pointer(&unlock)); err != nil { // TIOCSPTLCK
		t.Fatal(err)
	}
	if err := ioctl(int(m.Fd()), 0x80045430, unsafe.Pointer(&num)); err != nil { // TIOCGPTN
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = m.Close() })
	return m, fmt.Sprintf("/dev/pts/%d", num)
}

func TestPTYCapture(t *testing.T) {
	master, slave := openPTY(t)
	dir := t.TempDir()
	out, logPath := filepath.Join(dir, "o.json"), filepath.Join(dir, "cap.log")
	go func() {
		time.Sleep(300 * time.Millisecond)
		_, _ = master.Write([]byte{0x81, 0x00, 0x17})
		time.Sleep(300 * time.Millisecond)
		_, _ = master.Write([]byte("\r\n\x03\x00\xff")) // bytes a cooked terminal would translate or act on
	}()
	rc, _, stderr := runCmd(t, SerialFrameCapture, "capture", "--port", slave, "--baud", "19200", "--seconds", "1.2", "--allow-live-probe", "--log", logPath, "--output", out)
	if rc != 0 || stderr != "" {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	doc := evidence(t, out)
	frames := arr(doc["frames"])
	if len(frames) != 2 || obj(frames[0])["hex"] != "810017" || obj(frames[1])["hex"] != "0d0a030"+"0ff" {
		t.Fatalf("frames = %v, want the two writes unchanged (raw mode: no CR/NL translation, no signals)", frames)
	}
	if t1 := obj(frames[0])["t_rel_s"].(float64); t1 < 0.25 || t1 > 0.6 {
		t.Errorf("first frame time = %v, want about 0.3s", t1)
	}
	if !strings.Contains(readFile(t, logPath), "  len=3  81 00 17\n") {
		t.Errorf("log = %q", readFile(t, logPath))
	}
}

func TestPTYSweep(t *testing.T) {
	master, slave := openPTY(t)
	go func() {
		for range 40 {
			_, _ = master.Write([]byte("hello hello hello hello hello hello hello hello"))
			time.Sleep(10 * time.Millisecond)
		}
	}()
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := runCmd(t, SerialFrameCapture, "sweep", "--port", slave, "--seconds", "0.1", "--allow-live-probe", "--output", out)
	if rc != 0 || stderr != "" {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	doc := evidence(t, out)
	if doc["status"] != "complete" || len(arr(obj(doc["results"])["baud_rates"])) != 7 {
		t.Errorf("doc = %v", doc)
	}
}

func TestPTYConfiguration(t *testing.T) {
	_, slave := openPTY(t)
	for _, baud := range []int64{9600, 115200, 4000000, 12345} {
		p, err := openSerialPort(slave, baud)
		if err != nil {
			t.Fatalf("baud %d: %v", baud, err)
		}
		tp := p.(*ttyPort)
		var tio syscall.Termios
		if err := ioctl(int(tp.f.Fd()), syscall.TCGETS, unsafe.Pointer(&tio)); err != nil {
			t.Fatal(err)
		}
		if tio.Lflag&(syscall.ICANON|syscall.ECHO|syscall.ISIG) != 0 || tio.Oflag&syscall.OPOST != 0 ||
			tio.Iflag&(syscall.ICRNL|syscall.INLCR|syscall.IXON|syscall.ISTRIP) != 0 {
			t.Errorf("baud %d: not raw: %+v", baud, tio)
		}
		if tio.Cflag&syscall.CSIZE != syscall.CS8 || tio.Cflag&(syscall.PARENB|syscall.CSTOPB) != 0 ||
			tio.Cflag&(syscall.CLOCAL|syscall.CREAD) != syscall.CLOCAL|syscall.CREAD {
			t.Errorf("baud %d: not 8N1: cflag %#o", baud, tio.Cflag)
		}
		if tio.Cc[syscall.VMIN] != 0 || tio.Cc[syscall.VTIME] != 0 {
			t.Errorf("baud %d: VMIN/VTIME = %d/%d, want 0/0", baud, tio.Cc[syscall.VMIN], tio.Cc[syscall.VTIME])
		}
		if speed, ok := standardBauds[baud]; ok && tio.Cflag&cbaud != speed {
			t.Errorf("baud %d: speed bits %#o, want %#o", baud, tio.Cflag&cbaud, speed)
		}
		if _, ok := standardBauds[baud]; !ok && tio.Cflag&cbaud != bother {
			t.Errorf("baud %d: custom rate not applied (cflag %#o)", baud, tio.Cflag)
		}
		_ = p.Close()
	}
}

func TestPTYOpenErrors(t *testing.T) {
	for _, tc := range []struct {
		port string
		baud int64
		want string
	}{
		{"/dev/ttySTUB0", 9600, "[Errno 2] could not open port /dev/ttySTUB0: [Errno 2] No such file or directory: '/dev/ttySTUB0'"},
		{"/dev/null", 9600, "Could not configure port: (25, 'Inappropriate ioctl for device')"},
		{"/dev/null", -1, "Not a valid baudrate: -1"},
	} {
		_, err := openSerialPort(tc.port, tc.baud)
		if err == nil || err.Error() != tc.want {
			t.Errorf("%s @ %d: err = %v, want %q", tc.port, tc.baud, err, tc.want)
		}
	}
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := runCmd(t, SerialFrameCapture, "capture", "--port", "/dev/null", "--baud", "9600", "--allow-live-probe", "--output", out)
	if rc != 2 || stderr != "serial-frame-capture: /dev/null: Could not configure port: (25, 'Inappropriate ioctl for device')\n" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
	// sweep records the same failure per baud and exits 1
	rc, _, _ = runCmd(t, SerialFrameCapture, "sweep", "--port", "/dev/null", "--seconds", "0.1", "--allow-live-probe", "--output", filepath.Join(t.TempDir(), "s.json"))
	if rc != 1 {
		t.Errorf("sweep on a non-tty: rc = %d, want 1", rc)
	}
}

func TestPTYHangup(t *testing.T) {
	master, slave := openPTY(t)
	go func() {
		time.Sleep(200 * time.Millisecond)
		_ = master.Close()
	}()
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := runCmd(t, SerialFrameCapture, "capture", "--port", slave, "--baud", "9600", "--seconds", "3", "--allow-live-probe", "--output", out)
	if rc != 2 || !strings.HasPrefix(stderr, "serial-frame-capture: "+slave+": ") {
		t.Errorf("rc = %d stderr = %q, want exit 2 naming the port", rc, stderr)
	}
}

func TestTTYReadTimeout(t *testing.T) {
	_, slave := openPTY(t)
	p, err := openSerialPort(slave, 9600)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = p.Close() }()
	start := time.Now()
	got, err := p.Read(256, 60*time.Millisecond)
	if err != nil || len(got) != 0 || time.Since(start) < 55*time.Millisecond || time.Since(start) > 2*time.Second {
		t.Errorf("idle read: %v %v after %v, want an empty result after about the timeout", got, err, time.Since(start))
	}
}
