package a

type runner struct{}

func (runner) Command(string) {}

var exec runner

func run10() { exec.Command("python3") }
