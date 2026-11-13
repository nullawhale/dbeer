package mysql

import (
	"strings"
	"unicode/utf8"
)

const nativeBrowseIdentityMessage = "The native filter target identity is unavailable or ambiguous. Refresh the table metadata and retry."
const nativePrimaryKeyQuery = `SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND CONSTRAINT_NAME='PRIMARY'
ORDER BY ORDINAL_POSITION LIMIT 1001`
const nativeBrowseColumnsQuery = `SELECT COLUMN_NAME,DATA_TYPE,CHARACTER_SET_NAME FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION LIMIT 4097`

// INFORMATION_SCHEMA name collations can fold case and accents even when the
// server resolves those physical objects separately. Match the server's case
// mode without folding accents, require one target, and retain its exact names.
func nativeBrowseTargetSQL(lowerCase int64) (string, error) {
	switch lowerCase {
	case 0:
		return `SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 2`, nil
	case 1, 2:
		return `SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES WHERE BINARY LOWER(TABLE_SCHEMA)=BINARY LOWER(?) AND BINARY LOWER(TABLE_NAME)=BINARY LOWER(?) LIMIT 2`, nil
	default:
		return "", invalidSettings(nativeBrowseIdentityMessage)
	}
}

// This shared read-only resolver also verifies UTF8 identifier/result encodings;
// callers may reuse it for authoritative comparison metadata without changing
// session settings or reading table rows.
func (session *Session) nativeBrowseTarget(schema, table string) (string, string, error) {
	if err := session.requireNativeMetadataEncoding(); err != nil {
		return "", "", err
	}
	mode, err := session.work.client.Execute(`SELECT @@lower_case_table_names`)
	if err != nil {
		return "", "", err
	}
	lowerCase, decodeErr := mode.GetInt(0, 0)
	mode.Close()
	if decodeErr != nil {
		return "", "", invalidSettings(nativeBrowseIdentityMessage)
	}
	statement, err := nativeBrowseTargetSQL(lowerCase)
	if err != nil {
		return "", "", err
	}
	target, err := session.work.client.Execute(statement, schema, table)
	if err != nil {
		return "", "", err
	}
	defer target.Close()
	if target.RowNumber() != 1 {
		return "", "", invalidSettings(nativeBrowseIdentityMessage)
	}
	actualSchema, schemaErr := target.GetString(0, 0)
	actualTable, tableErr := target.GetString(0, 1)
	if schemaErr != nil || tableErr != nil || !nativeMetadataNameValid(actualSchema) || !nativeMetadataNameValid(actualTable) {
		return "", "", invalidSettings(nativeBrowseIdentityMessage)
	}
	return strings.Clone(actualSchema), strings.Clone(actualTable), nil
}

func nativeMetadataNameValid(value string) bool {
	return value != "" && len(value) <= 1024 && utf8.ValidString(value) && !strings.ContainsRune(value, 0)
}
