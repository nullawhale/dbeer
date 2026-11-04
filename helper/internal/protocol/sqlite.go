package protocol

import (
	"dbeer/helper/internal/sqlitevalue"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

type SQLiteSettings struct {
	Path string `json:"path"`
}

func (s SQLiteSettings) Valid() bool {
	return filepath.IsAbs(s.Path) && utf8.ValidString(s.Path) && len(s.Path) <= 32768 && !strings.ContainsRune(s.Path, 0)
}

// SQLiteValue is the shared per-cell SQLite storage representation.
type SQLiteValue = sqlitevalue.Value
