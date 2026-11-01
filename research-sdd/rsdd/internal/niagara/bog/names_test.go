package bog

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// pyCP437 is bytes(range(128, 256)).decode("cp437") from CPython 3.15.
const pyCP437 = "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "

// CPython decodes a member name stored without the UTF-8 flag as code page 437, whatever the bytes are; the
// audit judges signature members by name, so Names must agree with namelist().
func TestNamesFollowThePythonDecoding(t *testing.T) {
	high := make([]byte, 128)
	for i := range high {
		high[i] = byte(0x80 + i)
	}
	tests := []struct {
		name  string
		entry bogtest.Entry
		want  string
	}{
		{"ascii is untouched", bogtest.Entry{Name: "META-INF/module.xml"}, "META-INF/module.xml"},
		{"utf-8 bytes without the flag read as cp437", bogtest.Entry{Name: "caf\xc3\xa9"}, "caf├⌐"},
		{"the UTF-8 flag keeps the text", bogtest.Entry{Name: "caf\xc3\xa9", Flags: 0x800}, "café"},
		{"every high byte", bogtest.Entry{Name: string(high)}, pyCP437},
		{"long s is not an S", bogtest.Entry{Name: "x.R\xc5\xbfA"}, "x.R┼┐A"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			z, err := OpenZip(bogtest.Zip(tt.entry))
			if err != nil {
				t.Fatal(err)
			}
			if got := z.Names(); len(got) != 1 || got[0] != tt.want {
				t.Errorf("Names() = %q, want %q", got, tt.want)
			}
		})
	}
}

// A member is found by the name Names reports.
func TestReadMemberUsesTheDecodedName(t *testing.T) {
	z, err := OpenZip(bogtest.Zip(bogtest.Entry{Name: "caf\xc3\xa9", Data: []byte("body")}))
	if err != nil {
		t.Fatal(err)
	}
	body, _, err := z.ReadMember("caf├⌐", MaxInflate)
	if err != nil || string(body) != "body" {
		t.Errorf("ReadMember(decoded name) = %q, %v", body, err)
	}
}
