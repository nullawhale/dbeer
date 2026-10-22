package protocol

import (
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// PasswordCommand is local executable configuration, never a cached credential.
// Omission selects the password supplied by the platform credential store.
type PasswordCommand struct {
	Executable string   `json:"executable"`
	Arguments  []string `json:"arguments"`
}

func (command PasswordCommand) Valid() bool {
	if !filepath.IsAbs(command.Executable) || len(command.Executable) > 4096 ||
		!utf8.ValidString(command.Executable) || strings.ContainsRune(command.Executable, 0) || len(command.Arguments) > 128 {
		return false
	}
	size := len(command.Executable)
	for _, argument := range command.Arguments {
		size += len(argument)
		if !utf8.ValidString(argument) || strings.ContainsRune(argument, 0) {
			return false
		}
	}
	return size <= 65536
}
