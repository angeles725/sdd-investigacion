package bacnet

import (
	"math"
	"math/big"
	"sort"
	"time"
)

// probeConfig is what the live probe needs from the command line.
type probeConfig struct {
	host, bbmd, localBcast string
	port                   *big.Int
	timeout                time.Duration
}

// reply is one valid BVLC datagram: who sent it, the I-Am instance it carried (if any) and the raw bytes.
type reply struct {
	ip      string
	inst    uint32
	hasInst bool
	raw     []byte
}

// minRead is the shortest read window a collection loop arms, as the legacy tool's max(0.01, remaining).
const minRead = 10 * time.Millisecond

// collect drains datagrams until the deadline or the first read error, keeping those that are BVLC frames.
func collect(l link, clock func() time.Time, window time.Duration, wantIAm bool) []reply {
	deadline := clock().Add(window)
	var out []reply
	for {
		rem := deadline.Sub(clock())
		if rem <= 0 {
			break
		}
		if rem < minRead {
			rem = minRead
		}
		ip, data, err := l.recv(clock().Add(rem))
		if err != nil {
			break
		}
		fn, payload, ok := parseBVLC(data)
		if !ok {
			continue
		}
		r := reply{ip: ip, raw: data}
		if wantIAm {
			r.inst, r.hasInst = extractIAm(fn, payload)
		}
		out = append(out, r)
	}
	return out
}

func sortedInts(set map[int]bool) []int {
	out := make([]int, 0, len(set))
	for v := range set {
		out = append(out, v)
	}
	sort.Ints(out)
	return out
}

// checkTimeout is what socket.settimeout does with the value: NaN and negative values are a ValueError, a value
// that does not fit a 64-bit nanosecond count is an OverflowError. Its text is ours: CPython words it per version (3.12 "platform time_t", 3.15 "C PyTime_t").
func checkTimeout(sec float64) *pyError {
	if math.IsNaN(sec) {
		return &pyError{kind: "ValueError", msg: "Invalid value NaN (not a number)"}
	}
	if ns := sec * 1e9; ns >= 9223372036854775808.0 || ns < -9223372036854775808.0 {
		return &pyError{kind: "OverflowError", msg: "timeout value out of range"}
	}
	if sec < 0 {
		return &pyError{kind: "ValueError", msg: "Timeout value out of range"}
	}
	return nil
}

// probeLive runs the three probes and the verdict. It returns the evidence document and the exit code.
func probeLive(l link, clock func() time.Time, c probeConfig) (map[string]any, int, error) {
	probes := map[string]any{}
	result := map[string]any{
		"schema": "bacnet-evidence.v1", "status": "complete",
		"host": c.host, "port": jsonInt(c.port), "probes": probes,
	}

	// 1 - directed unicast Who-Is
	if err := l.send(buildWhoIs(false), c.host, c.port); err != nil {
		return nil, 0, err
	}
	var hit *reply
	for _, r := range collect(l, clock, c.timeout, true) {
		if r.ip == c.host && r.hasInst {
			r := r
			hit = &r
			break
		}
	}
	unicast := map[string]any{"reachable": hit != nil, "instance": nil}
	if hit != nil {
		unicast["instance"] = int(hit.inst)
	}
	probes["unicast_who_is"] = unicast

	// 2 - local broadcast Who-Is
	var crossed map[string]any
	if c.localBcast != "" {
		if err := l.send(buildWhoIs(true), c.localBcast, c.port); err != nil {
			return nil, 0, err
		}
		seen := map[string]map[int]bool{}
		for _, r := range collect(l, clock, c.timeout, true) {
			if r.hasInst {
				if seen[r.ip] == nil {
					seen[r.ip] = map[int]bool{}
				}
				seen[r.ip][int(r.inst)] = true
			}
		}
		responders, crossed2, local := map[string]any{}, map[string]any{}, map[string]any{}
		for ip, set := range seen {
			v := sortedInts(set)
			responders[ip] = v
			if sameSlash24(ip, c.host) {
				crossed2[ip] = v
			} else {
				local[ip] = v
			}
		}
		crossed = crossed2
		probes["broadcast_who_is"] = map[string]any{
			"local_bcast": c.localBcast, "responders": responders,
			"crossed_from_target_subnet": crossed2, "same_as_local": local,
		}
	} else {
		probes["broadcast_who_is"] = map[string]any{
			"local_bcast": nil, "note": "--local-bcast not provided; broadcast Who-Is skipped",
		}
	}

	// 3 - Read-BDT / Read-FDT against the candidate BBMDs (the host first, each once)
	var candidates []string
	for _, t := range []string{c.host, c.bbmd} {
		if t == "" || (len(candidates) > 0 && candidates[0] == t) {
			continue
		}
		candidates = append(candidates, t)
	}
	bbmds := map[string]any{}
	anyBBMD := false
	for _, tgt := range candidates {
		if err := l.send(buildReadBDT(), tgt, c.port); err != nil {
			return nil, 0, err
		}
		entry := map[string]any{"is_bbmd": false, "bdt": nil, "fdt": nil}
		for _, r := range collect(l, clock, c.timeout, false) {
			if bdt, ok := parseBDTAck(r.raw); ok {
				entry["is_bbmd"], entry["bdt"] = true, bdt
			}
		}
		if entry["is_bbmd"] == true {
			anyBBMD = true
			if err := l.send(buildReadFDT(), tgt, c.port); err != nil {
				return nil, 0, err
			}
			for _, r := range collect(l, clock, c.timeout, false) {
				if fdt, ok := parseFDTAck(r.raw); ok {
					entry["fdt"] = fdt
				}
			}
		}
		bbmds[tgt] = entry
	}
	probes["bbmd_probe"] = bbmds

	// verdict
	var code, verdict string
	switch {
	case len(crossed) > 0 || anyBBMD:
		code = "ok"
		verdict = "REBIND OK — broadcast Who-Is reaches the target subnet"
		if anyBBMD {
			verdict += " (BBMD confirmed)"
		}
		verdict += ". Instance-based re-binding will work on an IP change."
	case hit != nil:
		code = "rebind_fail"
		verdict = "REBIND WILL FAIL — device responds to unicast but NOT broadcast Who-Is, " +
			"and no BBMD answered. Configure a BBMD/Foreign-Device path or use a " +
			"static IP / DHCP reservation."
	default:
		code = "inconclusive"
		verdict = "INCONCLUSIVE — device did not respond to directed unicast Who-Is. " +
			"Verify --host, --port, firewall rules, and routing."
	}
	result["verdict_code"], result["verdict"] = code, verdict
	if code == "ok" {
		return result, 0, nil
	}
	return result, 1, nil
}
