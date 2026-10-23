package commands

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func cmd(group, name string) cli.Command {
	return cli.Command{Group: group, Name: name, Summary: "s", Run: func([]string, cli.Stdio) int { return 0 }}
}

func TestAssembleConcatenatesDomains(t *testing.T) {
	got, err := assemble([]namedSet{
		{"verify", []cli.Command{cmd("verify", "block")}},
		{"gate", []cli.Command{cmd("gate", "retro"), cmd("gate", "merge")}},
		{"empty", nil},
	})
	if err != nil || len(got) != 3 {
		t.Fatalf("got (%d commands, %v), want 3 and no error", len(got), err)
	}
}

func TestAssembleRejectsDuplicateAcrossDomains(t *testing.T) {
	_, err := assemble([]namedSet{
		{"verify", []cli.Command{cmd("verify", "block")}},
		{"lint", []cli.Command{cmd("verify", "block")}},
	})
	if err == nil || !strings.Contains(err.Error(), "duplicate") || !strings.Contains(err.Error(), "verify") || !strings.Contains(err.Error(), "lint") {
		t.Fatalf("err = %v, want a duplicate error naming both domains", err)
	}
}

func TestAssembleRejectsGroupShadowingCommand(t *testing.T) {
	_, err := assemble([]namedSet{
		{"a", []cli.Command{cmd("", "gate")}},
		{"b", []cli.Command{cmd("gate", "retro")}},
	})
	if err == nil || !strings.Contains(err.Error(), "collides") {
		t.Fatalf("err = %v, want a group/command collision", err)
	}
}

func TestDuplicateMessageLabelsGroupedAndUngrouped(t *testing.T) {
	_, err := assemble([]namedSet{{"a", []cli.Command{cmd("", "solo")}}, {"b", []cli.Command{cmd("", "solo")}}})
	if err == nil || !strings.Contains(err.Error(), `"solo"`) {
		t.Errorf("ungrouped label: %v", err)
	}
	_, err = assemble([]namedSet{{"a", []cli.Command{cmd("g", "n")}}, {"b", []cli.Command{cmd("g", "n")}}})
	if err == nil || !strings.Contains(err.Error(), `"g n"`) {
		t.Errorf("grouped label: %v", err)
	}
}
