package firmware

import "syscall"

func statOf(st *syscall.Stat_t) statTuple {
	return statTuple{uint64(st.Dev), uint64(st.Ino), uint32(st.Mode), int64(st.Size), int64(st.Mtim.Sec)*1e9 + int64(st.Mtim.Nsec), int64(st.Ctim.Sec)*1e9 + int64(st.Ctim.Nsec)}
}
