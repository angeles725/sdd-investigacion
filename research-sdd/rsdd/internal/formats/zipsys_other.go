//go:build !linux

package formats

import (
	"errors"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

var errZipPlatform = errors.New("the ZIP readers require Linux (/proc, renameat2)")

type zipInput struct{}

func zipOpenInput(string) (*zipInput, fsx.Stat, error) { return nil, fsx.Stat{}, errZipPlatform }
func (*zipInput) Close() error                         { return nil }
func (*zipInput) ReadAt([]byte, int64) (int, error)    { return 0, errZipPlatform }
func (*zipInput) Stat() (fsx.Stat, error)              { return fsx.Stat{}, errZipPlatform }
func (*zipInput) Resolved() string                     { return "" }

func zipOwnerOf(os.FileInfo) (uint32, uint64, bool) { return 0, 0, false }

var zipGetuid = func() int { return -1 }
