package firmware

import "syscall"

func statOf(st *syscall.Stat_t) statTuple {
	return statTuple{uint64(st.Dev), uint64(st.Ino), uint32(st.Mode), int64(st.Size), int64(st.Mtimespec.Sec)*1e9 + int64(st.Mtimespec.Nsec), int64(st.Ctimespec.Sec)*1e9 + int64(st.Ctimespec.Nsec)}
}
