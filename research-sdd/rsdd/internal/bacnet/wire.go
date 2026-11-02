package bacnet

import (
	"fmt"
	"slices"
	"strings"
)

// Wire constants (ANSI/ASHRAE 135 BACnet/IP), as in the legacy corroborate_bacnet.py.
const (
	bvlcType            = 0x81
	fnOriginalUnicast   = 0x0A
	fnOriginalBroadcast = 0x0B
	fnForwardedNPDU     = 0x04
	fnReadBDT           = 0x02
	fnReadBDTAck        = 0x03
	fnReadFDT           = 0x06
	fnReadFDTAck        = 0x07
	apduUnconfirmed     = 0x10
	svcWhoIs            = 0x08
	svcIAm              = 0x00
	// defaultPort is 0xBAC0.
	defaultPort = 47808
)

// bvlc frames a payload: type, function, big-endian total length (header included).
func bvlc(fn byte, payload []byte) []byte {
	n := 4 + len(payload)
	return append([]byte{bvlcType, fn, byte(n >> 8), byte(n)}, payload...)
}

// buildWhoIs is the unconfirmed Who-Is without a device range, as a unicast or a broadcast frame.
func buildWhoIs(broadcast bool) []byte {
	fn := byte(fnOriginalUnicast)
	if broadcast {
		fn = fnOriginalBroadcast
	}
	return bvlc(fn, []byte{0x01, 0x00, apduUnconfirmed, svcWhoIs})
}

func buildReadBDT() []byte { return bvlc(fnReadBDT, nil) }

func buildReadFDT() []byte { return bvlc(fnReadFDT, nil) }

// parseBVLC returns the function code and the payload of a BVLC frame; the payload ends at the declared length
// when the datagram holds that much, and at the end of the datagram otherwise (a declared length below the
// header gives an empty payload).
func parseBVLC(data []byte) (fn byte, payload []byte, ok bool) {
	if len(data) < 4 || data[0] != bvlcType {
		return 0, nil, false
	}
	ln := int(data[2])<<8 | int(data[3])
	if ln <= len(data) {
		if ln < 4 {
			return data[1], []byte{}, true
		}
		return data[1], data[4:ln], true
	}
	return data[1], data[4:], true
}

// parseIAm returns the device instance of an I-Am APDU.
func parseIAm(apdu []byte) (uint32, bool) {
	if len(apdu) < 2 || apdu[0] != apduUnconfirmed || apdu[1] != svcIAm {
		return 0, false
	}
	body := apdu[2:]
	if len(body) < 5 || body[0] != 0xC4 {
		return 0, false
	}
	id := uint32(body[1])<<24 | uint32(body[2])<<16 | uint32(body[3])<<8 | uint32(body[4])
	if id>>22 != 8 { // 8 = device object
		return 0, false
	}
	return id & 0x3FFFFF, true
}

// extractIAm finds an I-Am in a BVLL payload: original unicast/broadcast carry the NPDU directly, a forwarded
// NPDU is prefixed by the 6-byte originating address. The DNET and SNET specifiers are skipped with the legacy
// tool's own layout (a 2-byte network, 1-byte length, then that many address bytes, for either bit), and the hop
// count byte follows when the DNET bit is set.
func extractIAm(fn byte, payload []byte) (uint32, bool) {
	var npdu []byte
	switch fn {
	case fnOriginalUnicast, fnOriginalBroadcast:
		npdu = payload
	case fnForwardedNPDU:
		if len(payload) < 6 {
			return 0, false
		}
		npdu = payload[6:]
	default:
		return 0, false
	}
	if len(npdu) < 2 {
		return 0, false
	}
	ctrl, idx := npdu[1], 2
	if ctrl&0x20 != 0 {
		if len(npdu) < idx+3 {
			return 0, false
		}
		idx += 3 + int(npdu[idx+2])
	}
	if ctrl&0x08 != 0 {
		if len(npdu) < idx+3 {
			return 0, false
		}
		idx += 3 + int(npdu[idx+2])
	}
	if ctrl&0x20 != 0 {
		idx++
	}
	if idx > len(npdu) {
		return 0, false
	}
	return parseIAm(npdu[idx:])
}

// addr6 formats a 6-byte BACnet/IP address as "A.B.C.D:0xPPPP".
func addr6(b []byte) string {
	return fmt.Sprintf("%d.%d.%d.%d:0x%04X", b[0], b[1], b[2], b[3], int(b[4])<<8|int(b[5]))
}

// parseBDTAck lists the entries of a Read-BDT-Ack: 10 bytes each, a trailing partial entry is ignored. A frame
// that is not a Read-BDT-Ack is ok=false; an ack without entries is an empty, non-nil list.
func parseBDTAck(data []byte) ([]map[string]any, bool) {
	fn, payload, ok := parseBVLC(data)
	if !ok || fn != fnReadBDTAck {
		return nil, false
	}
	entries := []map[string]any{}
	for i := 0; i+10 <= len(payload); i += 10 {
		entries = append(entries, map[string]any{
			"addr": addr6(payload[i : i+6]),
			"mask": fmt.Sprintf("%d.%d.%d.%d", payload[i+6], payload[i+7], payload[i+8], payload[i+9]),
		})
	}
	return entries, true
}

// parseFDTAck lists the entries of a Read-FDT-Ack: address, time-to-live and remaining seconds, 10 bytes each.
func parseFDTAck(data []byte) ([]map[string]any, bool) {
	fn, payload, ok := parseBVLC(data)
	if !ok || fn != fnReadFDTAck {
		return nil, false
	}
	entries := []map[string]any{}
	for i := 0; i+10 <= len(payload); i += 10 {
		entries = append(entries, map[string]any{
			"addr":        addr6(payload[i : i+6]),
			"ttl_s":       int(payload[i+6])<<8 | int(payload[i+7]),
			"remaining_s": int(payload[i+8])<<8 | int(payload[i+9]),
		})
	}
	return entries, true
}

// sameSlash24 compares the first three dot-separated fields of two address strings (the tool's fixed /24
// assumption); fewer than three fields compare as they are.
func sameSlash24(a, b string) bool {
	return slices.Equal(first3(a), first3(b))
}

func first3(s string) []string {
	p := strings.Split(s, ".")
	if len(p) > 3 {
		p = p[:3]
	}
	return p
}
