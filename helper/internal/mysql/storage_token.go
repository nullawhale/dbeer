package mysql

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func mysqlStoredChoice(kind string) bool {
	return kind == "enum" || kind == "set" || kind == "enumBinary" || kind == "setBinary"
}

func mysqlStorageKind(kind string) bool {
	return mysqlStoredChoice(kind) || kind == "float" || kind == "double" || kind == "timestamp"
}

func mysqlStableProjection(name, kind string) string {
	column := QuoteIdentifier(name)
	switch kind {
	case "float", "double":
		return "CAST(" + column + " AS DOUBLE)"
	case "timestamp":
		// AT TIME ZONE does not preserve the legacy zero timestamp sentinel.
		// Keep its exact text, including any stored fractional component.
		return "IF(LEFT(CAST(" + column + " AS CHAR),10)='0000-00-00',CAST(" + column + " AS CHAR),CAST(" + column + " AT TIME ZONE '+00:00' AS DATETIME(6)))"
	}
	return column
}

func mysqlStorageKinds(metadata editMetadata) map[string]string {
	kinds := map[string]string{}
	for _, column := range metadata.columns {
		kinds[column.name] = column.dataType
	}
	return kinds
}

func mysqlStorageColumns(metadata editMetadata) []string {
	names := []string{}
	for _, column := range metadata.columns {
		if mysqlStorageKind(column.dataType) {
			names = append(names, column.name)
		}
	}
	sort.Strings(names)
	return names
}

func mysqlStorageProjections(names []string, kinds map[string]string) []string {
	projections := make([]string, len(names))
	for i, name := range names {
		expression := "CAST(" + QuoteIdentifier(name) + " AS UNSIGNED)"
		if !mysqlStoredChoice(kinds[name]) {
			expression = "CAST(" + mysqlStableProjection(name, kinds[name]) + " AS CHAR CHARACTER SET ascii)"
		}
		projections[i] = expression + " AS " + QuoteIdentifier("__dbeer_storage_"+strconv.Itoa(i))
	}
	return projections
}

// Exact enum ordinals, set masks, promoted floats and UTC timestamps enter this
// opaque token. Their plaintext never appears in it; JSON distinguishes NULL.
func mysqlStorageToken(values []wire.FieldValue) (string, error) {
	if len(values) == 0 {
		return "", nil
	}
	ordinals := make([]*string, len(values))
	for i, value := range values {
		var ordinal string
		switch value.Type {
		case wire.FieldValueTypeNull:
			continue
		case wire.FieldValueTypeUnsigned:
			ordinal = strconv.FormatUint(value.AsUint64(), 10)
		case wire.FieldValueTypeSigned:
			if value.AsInt64() < 0 {
				return "", wire.ErrMalformPacket
			}
			ordinal = strconv.FormatInt(value.AsInt64(), 10)
		case wire.FieldValueTypeString:
			ordinal = string(value.AsString())
			if !utf8.ValidString(ordinal) || len(ordinal) > 128 {
				return "", wire.ErrMalformPacket
			}
		default:
			return "", wire.ErrMalformPacket
		}
		ordinals[i] = &ordinal
	}
	encoded, _ := json.Marshal(ordinals)
	digest := sha256.Sum256(encoded)
	return "mysql.storage.v1:" + hex.EncodeToString(digest[:]), nil
}

func mysqlBrowseStorageColumns(actual map[string]string) []string {
	names := []string{}
	for name, kind := range actual {
		if mysqlStorageKind(strings.TrimSpace(kind)) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}
