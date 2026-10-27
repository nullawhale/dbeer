package resultartifact

import (
	"os"
	"syscall"
)

func changeTime(info os.FileInfo) syscall.Timespec { return info.Sys().(*syscall.Stat_t).Ctim }
