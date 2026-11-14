package mysql

import (
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
)

const nativeTimestampMessage = "Native TIMESTAMP filters require a supported canonical MySQL UTC timestamp value."

// MySQL browse cells use mysqlStableProjection's UTC wall representation for
// TIMESTAMP. DATETIME is also the wire type of a canonical timestamp projection.
// Do not reinterpret an unknown temporal string through the target time_zone.
func nativeTimestampValue(value protocol.NativeCellFilterValue) (string, error) {
	fail := func() (string, error) { return "", invalidSettings(nativeTimestampMessage) }
	if value.SourceEngine != "mysql" || value.Cell.Kind != "text" || value.Cell.Value == nil {
		return fail()
	}
	native := strings.ToLower(strings.TrimSpace(value.SourceType))
	if index := strings.IndexByte(native, '('); index >= 0 {
		if !strings.HasSuffix(native, ")") {
			return fail()
		}
		precision := native[index+1 : len(native)-1]
		count, err := strconv.Atoi(precision)
		if err != nil || count < 0 || count > 6 || strconv.Itoa(count) != precision {
			return fail()
		}
		native = native[:index]
	}
	if native != "timestamp" && native != "datetime" {
		return fail()
	}
	text := *value.Cell.Value
	if len(text) < 19 || len(text) > 26 {
		return fail()
	}
	base := text[:19]
	fraction := ""
	if len(text) > 19 {
		if text[19] != '.' || len(text) == 20 {
			return fail()
		}
		fraction = text[20:]
		for _, digit := range fraction {
			if digit < '0' || digit > '9' {
				return fail()
			}
		}
	}
	// Zero/incomplete dates do not identify a UTC instant. Reject them
	// explicitly instead of allowing SQL modes to normalize them into NULL.
	parsed, err := time.Parse("2006-01-02 15:04:05", base)
	if err != nil || parsed.Year() < 1000 || parsed.Format("2006-01-02 15:04:05") != base {
		return fail()
	}
	return base + "." + fraction + strings.Repeat("0", 6-len(fraction)), nil
}

// The existing browse projection already expresses TIMESTAMP in UTC as
// DATETIME(6). Compare it to a validated DATETIME(6) parameter, so MySQL does
// not reinterpret that UTC wall value as a session-local TIMESTAMP.
func nativeTimestampProjection(name string) string { return mysqlStableProjection(name, "timestamp") }
