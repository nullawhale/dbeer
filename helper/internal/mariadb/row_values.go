package mariadb

import (
	"bytes"
	"encoding/base64"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func rowText(row []*string, index int) string {
	if index < 0 || index >= len(row) || row[index] == nil {
		return ""
	}
	return *row[index]
}
func rowInt(row []*string, index int) (int, bool) {
	n, err := strconv.Atoi(rowText(row, index))
	return n, err == nil
}

func mariaDBMetadataRows(execution *changeExecution, sql string, args ...any) ([][]*string, error) {
	result, err := execution.query(sql, args...)
	if err != nil {
		return nil, err
	}
	defer result.Close()
	if result.RowNumber() > 4096 {
		return nil, editFailure("validation", "The row-write metadata exceeds its column limit.")
	}
	rows := make([][]*string, result.RowNumber())
	size := 0
	for i := range rows {
		if len(result.Values[i]) != len(result.Fields) {
			return nil, editFailure("validation", "The row-write metadata is incomplete.")
		}
		rows[i] = make([]*string, len(result.Fields))
		for j := range result.Fields {
			if result.Values[i][j].Type == wire.FieldValueTypeNull {
				continue
			}
			value, err := result.GetString(i, j)
			if err != nil {
				return nil, err
			}
			size += len(value)
			if len(value) > 1024*1024 || size > 4*1024*1024 || !utf8.ValidString(value) {
				return nil, editFailure("validation", "The row-write metadata exceeds its text limit.")
			}
			value = strings.Clone(value)
			rows[i][j] = &value
		}
	}
	return rows, nil
}

const mariaDBWriteStateSQL = "SELECT @@SESSION.sql_mode,@@SESSION.time_zone,@@SESSION.explicit_defaults_for_timestamp,@@SESSION.character_set_client,@@SESSION.character_set_connection,@@SESSION.character_set_results,@@SESSION.autocommit,@@SESSION.innodb_lock_wait_timeout,@@SESSION.lock_wait_timeout,@@SESSION.system_versioning_asof"

type mariaDBWriteScope struct {
	state      []string
	strictMode string
}

func loadMariaDBWriteScope(execution *changeExecution) (mariaDBWriteScope, error) {
	rows, err := mariaDBMetadataRows(execution, mariaDBWriteStateSQL)
	if err != nil {
		return mariaDBWriteScope{}, err
	}
	if len(rows) != 1 || len(rows[0]) != 10 {
		return mariaDBWriteScope{}, editFailure("validation", "The native row-write session state is unavailable.")
	}
	scope := mariaDBWriteScope{state: make([]string, 10)}
	for i, value := range rows[0] {
		if value == nil {
			return scope, editFailure("validation", "The native row-write session state is incomplete.")
		}
		scope.state[i] = *value
	}
	for _, i := range []int{3, 4, 5} {
		if scope.state[i] != "utf8mb4" {
			return scope, editFailure("validation", "Row writes require already active utf8mb4 client, connection and result encodings. Restore those settings explicitly before continuing.")
		}
	}
	mode := scope.state[0]
	if len(mode) > 4096 {
		return scope, editFailure("validation", "The native SQL mode exceeds its supported bound.")
	}
	seen := map[string]bool{}
	modes := []string{}
	if mode != "" {
		for _, part := range strings.Split(mode, ",") {
			if part == "" {
				return scope, editFailure("validation", "The native SQL mode is malformed.")
			}
			for _, c := range part {
				if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
					return scope, editFailure("validation", "The native SQL mode cannot be safely bound to this row workflow.")
				}
			}
			if !seen[part] {
				modes = append(modes, part)
				seen[part] = true
			}
		}
	}
	for _, required := range []string{"STRICT_ALL_TABLES", "NO_AUTO_VALUE_ON_ZERO"} {
		if !seen[required] {
			modes = append(modes, required)
		}
	}
	if seen["EMPTY_STRING_IS_NULL"] {
		return scope, editFailure("validation", "The active MariaDB EMPTY_STRING_IS_NULL mode converts empty prepared values to SQL NULL. Change that mode explicitly before using this row-write or import workflow.")
	}
	if seen["ORACLE"] {
		return scope, editFailure("validation", "The active MariaDB ORACLE mode changes prepared parameter syntax. Change that mode explicitly before using this row-write or import workflow.")
	}
	scope.strictMode = strings.Join(modes, ",")
	return scope, nil
}

// Native per-statement scope restores these values even on a statement error;
// the reviewed SQL includes the complete strict mode and UTC interpretation.
func (scope mariaDBWriteScope) wrap(sql string) string {
	return "SET STATEMENT sql_mode='" + scope.strictMode + "',time_zone='+00:00',innodb_lock_wait_timeout=5,lock_wait_timeout=5 FOR " + sql
}

func (scope mariaDBWriteScope) verify(execution *changeExecution) error {
	rows, err := mariaDBMetadataRows(execution, mariaDBWriteStateSQL)
	if err != nil {
		return err
	}
	if len(rows) != 1 || len(rows[0]) != len(scope.state) {
		return editFailure("validation", "The native row-write session state changed.")
	}
	for i, expected := range scope.state {
		if rows[0][i] == nil || *rows[0][i] != expected {
			return editFailure("validation", "The native row-write session state changed. The batch was not committed.")
		}
	}
	return nil
}

func sameSnapshot(metadata editMetadata, result *wire.Result, original []protocol.CellValue, storageToken string) bool {
	storageCount := len(MariaDBStorageColumns(storageKinds(metadata)))
	if result.RowNumber() != 1 || len(result.Fields) != len(original)+storageCount || len(result.Values[0]) != len(original)+storageCount || len(metadata.columns) != len(original) {
		return false
	}
	if storageCount > 0 {
		actual, err := MariaDBStorageToken(result.Values[0][len(original):])
		if err != nil || actual != storageToken {
			return false
		}
	} else if storageToken != "" {
		return false
	}
	for index, value := range result.Values[0][:len(original)] {
		expected := original[index]
		if value.Type == wire.FieldValueTypeNull {
			if expected.Kind != "null" {
				return false
			}
			continue
		}
		if expected.Value == nil {
			return false
		}
		kind := metadata.columns[index].dataType
		if storageCount > 0 && (kind == "float" || kind == "double" || kind == "timestamp") {
			continue
		}
		if metadata.columns[index].binary {
			if expected.Kind != "binary" {
				return false
			}
			decoded, err := base64.StdEncoding.DecodeString(*expected.Value)
			if err != nil || !bytes.Equal(decoded, value.AsString()) {
				return false
			}
			continue
		}
		if expected.Kind != "text" {
			return false
		}
		var actual string
		switch value.Type {
		case wire.FieldValueTypeString:
			actual = string(value.AsString())
		case wire.FieldValueTypeUnsigned:
			actual = strconv.FormatUint(value.AsUint64(), 10)
		case wire.FieldValueTypeSigned:
			actual = strconv.FormatInt(value.AsInt64(), 10)
		case wire.FieldValueTypeFloat:
			actual = strconv.FormatFloat(value.AsFloat64(), 'g', -1, 64)
		default:
			return false
		}
		if kind == "datetime" || kind == "timestamp" || kind == "time" {
			if trimTemporal(actual) != trimTemporal(*expected.Value) {
				return false
			}
		} else if actual != *expected.Value {
			return false
		}
	}
	return true
}

func trimTemporal(value string) string {
	if strings.Contains(value, ".") {
		return strings.TrimSuffix(strings.TrimRight(value, "0"), ".")
	}
	return value
}
