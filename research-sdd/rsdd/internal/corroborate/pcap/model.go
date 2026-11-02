package pcap

import (
	"encoding/json"
	"math/big"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// canonical is the evidence encoding: sorted keys, no spaces, ASCII escapes, one trailing newline.
func canonical(v any) ([]byte, error) { return jsonout.Canonical(v) }

// The evidence model shared by `pcap` and `pcap-flows`: one value type per row the two tools publish. Every
// type renders itself as the map the canonical encoder sorts, so the two commands cannot drift apart.

// capSummary is the capinfos block of pcap-evidence.v1.
type capSummary struct {
	DurationSeconds float64
	DataSize        *big.Int
	Encapsulation   string
	FileSize        *big.Int
	Packets         *big.Int
}

func (c capSummary) toMap() map[string]any {
	return map[string]any{
		"capture_duration_s": c.DurationSeconds,
		"data_size_bytes":    json.Number(c.DataSize.String()),
		"encapsulation":      c.Encapsulation,
		"file_size_bytes":    json.Number(c.FileSize.String()),
		"packet_count":       json.Number(c.Packets.String()),
	}
}

// protocolRow is one line of the tshark -z io,phs hierarchy.
type protocolRow struct {
	Protocol string
	Level    int
	Frames   json.Number
	Bytes    json.Number
}

func (p protocolRow) toMap() map[string]any {
	return map[string]any{"bytes": p.Bytes, "frames": p.Frames, "level": p.Level, "protocol": p.Protocol}
}

// conversation is one tshark -z conv,<proto> row, endpoints in canonical order.
type conversation struct {
	EndpointA, EndpointB string
	FramesB2A, BytesB2A  json.Number
	FramesA2B, BytesA2B  json.Number
	FramesTotal          json.Number
	BytesTotal           json.Number
}

func (c conversation) toMap() map[string]any {
	return map[string]any{
		"endpoint_a": c.EndpointA, "endpoint_b": c.EndpointB,
		"frames_b2a": c.FramesB2A, "bytes_b2a": c.BytesB2A,
		"frames_a2b": c.FramesA2B, "bytes_a2b": c.BytesA2B,
		"frames_total": c.FramesTotal, "bytes_total": c.BytesTotal,
	}
}

// streamFollow is the digest of one reassembled TCP stream; the payload itself is never kept.
type streamFollow struct {
	Index       json.Number
	Client      string
	Server      string
	SHA256      string
	ClientBytes int
	ServerBytes int
	Complete    bool
}

func (f streamFollow) toMap() map[string]any {
	return map[string]any{
		"stream_index": f.Index, "client": f.Client, "server": f.Server,
		"payload_sha256": f.SHA256, "payload_bytes": f.ClientBytes + f.ServerBytes,
		"client_bytes": f.ClientBytes, "server_bytes": f.ServerBytes,
		"payload_complete": f.Complete,
	}
}

func protocolMaps(rows []protocolRow) []any {
	out := make([]any, len(rows))
	for i, r := range rows {
		out[i] = r.toMap()
	}
	return out
}

func conversationMaps(rows []conversation) []any {
	out := make([]any, len(rows))
	for i, r := range rows {
		out[i] = r.toMap()
	}
	return out
}

func followMaps(rows []streamFollow) []any {
	out := make([]any, len(rows))
	for i, r := range rows {
		out[i] = r.toMap()
	}
	return out
}
