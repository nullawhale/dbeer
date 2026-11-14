package mariadb

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func MariaDBStorageKind(kind string) bool {
	switch kind {
	case "enum", "set", "enumBinary", "setBinary", "float", "double", "timestamp":
		return true
	}
	return false
}

func MariaDBEditableKind(kind string) bool {
	switch kind {
	case "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "numeric", "float", "double", "bit", "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "date", "datetime", "timestamp", "time", "year", "enum", "set", "uuid", "inet4", "inet6", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection":
		return true
	}
	return false
}

// Storage fields have one canonical byte order shared by browse and row locks.
func MariaDBStorageColumns(actual map[string]string) []string {
	names := []string{}
	for name, kind := range actual {
		if MariaDBStorageKind(kind) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

func mariaDBStoredChoice(kind string) bool {
	return kind == "enum" || kind == "set" || kind == "enumBinary" || kind == "setBinary"
}

// TIMESTAMP is rendered as UTC text from its native epoch, without converting
// an ambiguous local DATETIME back into an instant or changing session state.
func MariaDBStableProjection(name, kind string) string {
	column := QuoteIdentifier(name)
	switch kind {
	case "float", "double":
		return "CAST(" + column + " AS DOUBLE)"
	case "timestamp":
		return "IF(LEFT(CAST(" + column + " AS CHAR),10)='0000-00-00',CAST(" + column + " AS CHAR),CONCAT(DATE_FORMAT(TIMESTAMPADD(SECOND,FLOOR(UNIX_TIMESTAMP(" + column + ")),CAST('1970-01-01 00:00:00' AS DATETIME)),'%Y-%m-%d %H:%i:%s'),'.',LPAD(MICROSECOND(" + column + "),6,'0')))"
	}
	return column
}

func MariaDBStorageProjections(names []string, kinds map[string]string) []string {
	projections := make([]string, len(names))
	seen := map[string]bool{}
	for index, name := range names {
		kind := kinds[name]
		if name == "" || len(name) > 256 || !utf8.ValidString(name) || strings.ContainsRune(name, 0) || seen[name] || !MariaDBStorageKind(kind) {
			return nil
		}
		seen[name] = true
		column := QuoteIdentifier(name)
		var expression string
		switch {
		case mariaDBStoredChoice(kind):
			expression = "CAST(" + column + " AS UNSIGNED)"
		case kind == "float" || kind == "double":
			// Promotion drops display-scale rounding; retain the native float
			// bits in the token instead of formatting them through JSON floats.
			expression = MariaDBStableProjection(name, kind)
		case kind == "timestamp":
			expression = "IF(LEFT(CAST(" + column + " AS CHAR),10)='0000-00-00',CONCAT('zero:',CAST(" + column + " AS CHAR)),CONCAT('epoch:',CAST(UNIX_TIMESTAMP(" + column + ") AS CHAR CHARACTER SET ascii)))"
		}
		projections[index] = expression + " AS " + QuoteIdentifier("__dbeer_storage_"+strconv.Itoa(index))
	}
	return projections
}

func MariaDBStorageToken(values []wire.FieldValue) (string, error) {
	if len(values) == 0 {
		return "", nil
	}
	encodedValues := make([]*string, len(values))
	for index, value := range values {
		var text string
		switch value.Type {
		case wire.FieldValueTypeNull:
			continue
		case wire.FieldValueTypeUnsigned:
			text = strconv.FormatUint(value.AsUint64(), 10)
		case wire.FieldValueTypeSigned:
			if value.AsInt64() < 0 {
				return "", wire.ErrMalformPacket
			}
			text = strconv.FormatInt(value.AsInt64(), 10)
		case wire.FieldValueTypeFloat:
			text = "float64bits:" + strconv.FormatUint(math.Float64bits(value.AsFloat64()), 16)
		case wire.FieldValueTypeString:
			text = string(value.AsString())
			if !utf8.ValidString(text) || len(text) > 256 {
				return "", wire.ErrMalformPacket
			}
		default:
			return "", wire.ErrMalformPacket
		}
		encodedValues[index] = &text
	}
	encoded, err := json.Marshal(encodedValues)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(encoded)
	return "mariadb.storage.v1:" + hex.EncodeToString(digest[:]), nil
}
