package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
)

// This checks known native dump text-metadata losses; it does not replace the
// utility's data/history snapshot or execute a stored default expression.
func (s *Session) databaseToolsNativeMetadata(ctx context.Context) (string, error) {
	limits := sc.Limits{Nodes: 256, Members: 2048, Bytes: 2 << 20, Scalar: 65536}
	r := &mariaSchemaCapture{s: s, ctx: ctx, spec: sc.CaptureSpec{Limits: limits}}
	state, e := r.rows("SELECT DATABASE(),@@character_set_client,@@character_set_connection,@@character_set_results")
	if e != nil {
		return "", e
	}
	if len(state) != 1 || len(state[0]) != 4 || state[0][0] == nil {
		return "", sc.ErrInvalid
	}
	for i := 1; i < 4; i++ {
		if mariaText(state[0], i) != "utf8mb4" {
			return "", sc.ErrInvalid
		}
	}
	schema := *state[0][0]
	rows, e := r.tracked("SELECT c.TABLE_NAME,c.COLUMN_NAME,c.DATA_TYPE,CAST(c.COLUMN_TYPE AS BINARY),c.CHARACTER_SET_NAME,CAST(c.COLUMN_DEFAULT AS BINARY),c.CHARACTER_MAXIMUM_LENGTH,c.NUMERIC_PRECISION,c.NUMERIC_SCALE,c.DATETIME_PRECISION FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON BINARY t.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY t.TABLE_NAME=BINARY c.TABLE_NAME WHERE BINARY c.TABLE_SCHEMA=BINARY DATABASE() AND t.TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED') AND c.DATA_TYPE IN ('enum','set','char','varchar','tinytext','text','mediumtext','longtext') ORDER BY BINARY c.TABLE_NAME,c.ORDINAL_POSITION")
	if e != nil {
		return "", e
	}
	names := map[string][]string{}
	for _, row := range rows {
		if len(row) != 10 || row[0] == nil || row[1] == nil || row[2] == nil || row[3] == nil {
			return "", sc.ErrInvalid
		}
		kind, charset := mariaText(row, 2), mariaText(row, 4)
		if kind == "enum" || kind == "set" {
			typ := mariaSchemaType(kind, mariaText(row, 3), charset, mariaText(row, 6), mariaText(row, 7), mariaText(row, 8), mariaText(row, 9))
			if !typ.Labels.Complete {
				return "The native MariaDB dump text metadata cannot prove exact binary or replacement-ambiguous enum/set label domains. Use a coordinated server-level backup for this database.", nil
			}
		}
		if charset != "" && charset != "binary" && row[5] != nil {
			if _, ok := mariaCatalogLiteral(*row[5]); ok {
				names[*row[0]] = append(names[*row[0]], *row[1])
			}
		}
	}
	fields := map[string]map[string]string{}
	for table, columns := range names {
		if len(fields) >= limits.Nodes {
			return "", sc.ErrLimit
		}
		native, e := r.trackNativeDefaults(sc.Ref{Kind: "table", Schema: schema, Name: table}, columns)
		if e != nil {
			return "", e
		}
		fields[table] = map[string]string{}
		for _, column := range columns {
			field := native[column]
			if field == nil || field.Charset == 63 {
				return "", sc.ErrInvalid
			}
			fields[table][column] = string(field.DefaultValue)
		}
	}
	for _, row := range rows {
		if native, present := fields[mariaText(row, 0)][mariaText(row, 1)]; present {
			literal, ok := mariaCatalogLiteral(mariaText(row, 5))
			if !ok || literal != native {
				return "The native MariaDB dump text metadata changes a stored literal text default, including unrepresentable supplementary characters. Use a coordinated server-level backup or explicitly repair that default before a logical dump.", nil
			}
		}
	}
	if e := r.nativeDefaultsFresh(); e != nil {
		return "", e
	}
	for _, read := range r.reads {
		current, e := r.read(read.sql, read.show, read.args...)
		if e != nil {
			return "", e
		}
		if mariaRowsDigest(current) != read.digest {
			return "", sc.ErrInvalid
		}
	}
	return "", nil
}
