package bacnet

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

// link is the UDP socket the probes talk through. The real one is a bound udp4 socket; the tests replace it.
type link interface {
	// send transmits one datagram to host:port. A failure is a *pyError with the text Python gave it.
	send(frame []byte, host string, port *big.Int) error
	// recv reads one datagram (at most 1500 bytes) before the deadline; any error ends the collection window.
	recv(deadline time.Time) (ip string, data []byte, err error)
	close()
}

// openLinkFn opens the probe socket; a test replaces it.
var openLinkFn = openUDPLink

// lookupIPv4 resolves a host name to IPv4 addresses; a test replaces it.
var lookupIPv4 = func(host string) ([]net.IP, error) {
	return net.DefaultResolver.LookupIP(context.Background(), "ip4", host)
}

// checkPort is CPython's range check on a socket address port: the C int conversion first, then 0-65535.
func checkPort(p *big.Int, caller string) *pyError {
	switch {
	case !p.IsInt64():
		return &pyError{kind: "OverflowError", msg: "Python int too large to convert to C long"}
	case p.Int64() > 1<<31-1:
		return &pyError{kind: "OverflowError", msg: "signed integer is greater than maximum"}
	case p.Int64() < -(1 << 31):
		return &pyError{kind: "OverflowError", msg: "signed integer is less than minimum"}
	case p.Int64() < 0 || p.Int64() > 0xffff:
		return &pyError{kind: "OverflowError", msg: caller + "(): port must be 0-65535."}
	}
	return nil
}

// inetAton reads the dotted forms of inet_aton(3) (1 to 4 parts; decimal, 0x hex or leading-0 octal; the last
// part fills the remaining bytes), which getaddrinfo accepts and Python therefore does too.
func inetAton(s string) (netip.Addr, bool) {
	parts := strings.Split(s, ".")
	if len(parts) > 4 {
		return netip.Addr{}, false
	}
	var v uint64
	for i, p := range parts {
		if p == "" {
			return netip.Addr{}, false
		}
		base, digits := 10, p
		switch {
		case len(p) > 2 && (p[:2] == "0x" || p[:2] == "0X"):
			base, digits = 16, p[2:]
		case len(p) > 1 && p[0] == '0':
			base, digits = 8, p[1:]
		}
		if strings.ContainsAny(digits, "+-_") {
			return netip.Addr{}, false
		}
		n, err := strconv.ParseUint(digits, base, 32)
		if err != nil {
			return netip.Addr{}, false
		}
		if i < len(parts)-1 {
			if n > 255 {
				return netip.Addr{}, false
			}
			v |= n << (8 * (3 - i))
			continue
		}
		if n >= 1<<(8*(5-len(parts))) {
			return netip.Addr{}, false
		}
		v |= n
	}
	return netip.AddrFrom4([4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}), true
}

// resolveIPv4 is how Python's AF_INET sendto turns its host string into an address: "" is INADDR_ANY,
// "<broadcast>" is 255.255.255.255, dotted numbers go through inet_aton, anything else is looked up.
func resolveIPv4(host string) (netip.Addr, *pyError) {
	switch host {
	case "":
		return netip.AddrFrom4([4]byte{}), nil
	case "<broadcast>":
		return netip.AddrFrom4([4]byte{255, 255, 255, 255}), nil
	}
	if a, ok := inetAton(host); ok {
		return a, nil
	}
	ips, err := lookupIPv4(host)
	if err == nil {
		for _, ip := range ips {
			if a, ok := netip.AddrFromSlice(ip); ok && a.Unmap().Is4() {
				return a.Unmap(), nil
			}
		}
	}
	var dns *net.DNSError
	if errors.As(err, &dns) && dns.IsTemporary && !dns.IsNotFound {
		return netip.Addr{}, &pyError{kind: "OSError", msg: "[Errno -3] Temporary failure in name resolution"}
	}
	return netip.Addr{}, &pyError{kind: "OSError", msg: "[Errno -2] Name or service not known"}
}

// udpLink is the real socket.
type udpLink struct{ conn *net.UDPConn }

// openUDPLink is _make_socket: a udp4 socket with SO_BROADCAST and SO_REUSEADDR, bound to 0.0.0.0:srcPort.
func openUDPLink(srcPort *big.Int) (link, error) {
	if e := checkPort(srcPort, "bind"); e != nil {
		return nil, e
	}
	lc := net.ListenConfig{Control: reuseAddr}
	pc, err := lc.ListenPacket(context.Background(), "udp4", "0.0.0.0:"+srcPort.String())
	if err != nil {
		return nil, &pyError{kind: "OSError", msg: fmt.Sprintf(
			"cannot bind :%s (%s); retry with --src-port 0", srcPort.String(), osErrorText(err, ""))}
	}
	return &udpLink{conn: pc.(*net.UDPConn)}, nil
}

func (l *udpLink) send(frame []byte, host string, port *big.Int) error {
	addr, e := resolveIPv4(host)
	if e != nil {
		return e
	}
	if e := checkPort(port, "sendto"); e != nil {
		return e
	}
	if _, err := l.conn.WriteToUDPAddrPort(frame, netip.AddrPortFrom(addr, uint16(port.Int64()))); err != nil {
		return &pyError{kind: "OSError", msg: osErrorText(err, "")}
	}
	return nil
}

func (l *udpLink) recv(deadline time.Time) (string, []byte, error) {
	if err := l.conn.SetReadDeadline(deadline); err != nil {
		return "", nil, err
	}
	buf := make([]byte, 1500)
	n, from, err := l.conn.ReadFromUDPAddrPort(buf)
	if err != nil {
		return "", nil, err
	}
	return from.Addr().Unmap().String(), buf[:n], nil
}

func (l *udpLink) close() { _ = l.conn.Close() }
