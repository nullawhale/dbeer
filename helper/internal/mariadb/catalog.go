package mariadb

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func QuoteIdentifier(value string) string { return "`" + strings.ReplaceAll(value, "`", "``") + "`" }
func catalogIdentity(name string) string {
	if len(name) <= 128 {
		return name
	}
	digest := sha256.Sum256([]byte(name))
	return hex.EncodeToString(digest[:])
}
func text(value string) *string { return &value }

func collectLoaded(collector *collector, target, loaded *wire.Result) error {
	target.Status, target.AffectedRows, target.InsertId, target.Warnings = loaded.Status, loaded.AffectedRows, loaded.InsertId, loaded.Warnings
	if loaded.Resultset == nil {
		return nil
	}
	if err := collector.columns(loaded); err != nil {
		return err
	}
	for _, row := range loaded.Values {
		if err := collector.row(row); err != nil {
			return err
		}
	}
	return nil
}
func collectCatalogRows(collector *collector, names []string, rows [][]*string) error {
	result := wire.NewResultReserveResultset(len(names))
	defer result.Close()
	result.Fields = make([]*wire.Field, len(names))
	for i, name := range names {
		result.Fields[i] = &wire.Field{Name: []byte(name), Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45}
	}
	if err := collector.columns(result); err != nil {
		return err
	}
	for _, row := range rows {
		values := make([]wire.FieldValue, len(row))
		for i, value := range row {
			if value == nil {
				values[i] = wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil)
			} else {
				values[i] = wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(*value))
			}
		}
		if err := collector.row(values); err != nil {
			return err
		}
	}
	return nil
}

func (s *Session) catalog(ctx context.Context, command protocol.Command, sinks ...adapter.ResultSink) protocol.Response {
	if command.Catalog == nil || !command.Catalog.Valid() {
		return s.featureUnavailable(command)
	}
	r := *command.Catalog
	if r.Kind == "browse" || r.Kind == "select" {
		return s.catalogBrowse(ctx, command, sinks...)
	}
	warning := false
	response := s.executeWith(ctx, command, func(collector *collector, result *wire.Result) error {
		if err := s.requireNativeMetadataEncoding(); err != nil {
			return err
		}
		if r.Kind == "definition" || r.Kind == "name" {
			return s.catalogDefinition(collector, r)
		}
		query, args, err := catalogQuery(r)
		if err != nil {
			return err
		}
		loaded, err := s.work.client.Execute(query, args...)
		if err != nil {
			return err
		}
		defer loaded.Close()
		warning = loaded.Warnings != 0
		if r.Kind == "objects" || r.Kind == "search" {
			for _, row := range loaded.Values {
				if len(row) > 3 && row[0].Type != wire.FieldValueTypeNull {
					row[3] = wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(catalogIdentity(string(row[0].AsString()))))
				}
			}
		}
		return collectLoaded(collector, result, loaded)
	}, sinks...)
	if warning && response.Type != "error" {
		response.DisplayNotice = "The server reported a catalog warning; this observation may be incomplete."
	}
	if response.Type == "error" && response.Category == "sql" {
		response.Message = "MariaDB catalog metadata is unavailable or access was denied."
	}
	return response
}

func (s *Session) catalogDefinition(collector *collector, r protocol.CatalogRequest) error {
	keyword := map[string]string{"table": "TABLE", "view": "VIEW", "sequence": "SEQUENCE", "function": "FUNCTION", "procedure": "PROCEDURE", "trigger": "TRIGGER"}[r.ObjectKind]
	if keyword == "" || r.Object == "" {
		return errors.New("This native MariaDB object kind has no catalog definition reader.")
	}
	if r.Kind == "name" {
		query, args, err := catalogObjectLookup(r)
		if err != nil {
			return err
		}
		loaded, err := s.work.client.Execute(query, args...)
		if err != nil {
			return err
		}
		defer loaded.Close()
		rows := [][]*string{}
		if loaded.RowNumber() == 1 {
			name, err := loaded.GetString(0, 0)
			if err != nil {
				return err
			}
			if r.Identity == "" || r.Identity == catalogIdentity(name) {
				rows = append(rows, []*string{text(QuoteIdentifier(r.Schema) + "." + QuoteIdentifier(name))})
			}
		}
		return collectCatalogRows(collector, []string{"name"}, rows)
	}
	loaded, err := s.work.client.Execute("SHOW CREATE " + keyword + " " + QuoteIdentifier(r.Schema) + "." + QuoteIdentifier(r.Object))
	if err != nil {
		return err
	}
	defer loaded.Close()
	rows := [][]*string{}
	if loaded.RowNumber() == 1 {
		index := -1
		for i, field := range loaded.Fields {
			name := strings.ToLower(string(field.Name))
			if strings.HasPrefix(name, "create ") || name == "sql original statement" {
				if index != -1 {
					return errors.New("Ambiguous native definition fields.")
				}
				index = i
			}
		}
		if index < 0 {
			return errors.New("Native definition field was not reported.")
		}
		definition, err := loaded.GetString(0, index)
		if err != nil {
			return err
		}
		rows = append(rows, []*string{text(r.Object), text(strings.Clone(definition))})
	}
	return collectCatalogRows(collector, []string{"name", "definition"}, rows)
}

func catalogObjectLookup(r protocol.CatalogRequest) (string, []any, error) {
	switch r.ObjectKind {
	case "table":
		return `SELECT TABLE_NAME FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED') LIMIT 1`, []any{r.Schema, r.Object}, nil
	case "view", "sequence":
		return `SELECT TABLE_NAME FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND TABLE_TYPE=? LIMIT 1`, []any{r.Schema, r.Object, strings.ToUpper(r.ObjectKind)}, nil
	case "function", "procedure":
		return `SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE BINARY ROUTINE_SCHEMA=BINARY ? AND BINARY ROUTINE_NAME=BINARY ? AND ROUTINE_TYPE=? LIMIT 1`, []any{r.Schema, r.Object, strings.ToUpper(r.ObjectKind)}, nil
	case "trigger":
		return `SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE BINARY TRIGGER_SCHEMA=BINARY ? AND BINARY TRIGGER_NAME=BINARY ? LIMIT 1`, []any{r.Schema, r.Object}, nil
	}
	return "", nil, errors.New("Unknown native MariaDB catalog object kind.")
}

func catalogQuery(r protocol.CatalogRequest) (string, []any, error) {
	args := []any{r.Schema, r.Object}
	switch r.Kind {
	case "completion":
		return mariaDBCompletionSQL, []any{r.Schema, r.Schema, r.Schema, r.Page * 200}, nil
	case "schemas":
		return `SELECT SCHEMA_NAME AS name,'schema' AS kind FROM information_schema.SCHEMATA ORDER BY BINARY SCHEMA_NAME LIMIT 1001`, nil, nil
	case "objects":
		switch r.ObjectKind {
		case "table":
			return `SELECT TABLE_NAME AS name,'table' AS kind,TABLE_SCHEMA AS ` + "`schema`" + `,TABLE_NAME AS identity FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED') ORDER BY BINARY TABLE_NAME LIMIT 1001`, []any{r.Schema}, nil
		case "view", "sequence":
			return `SELECT TABLE_NAME AS name,LOWER(TABLE_TYPE) AS kind,TABLE_SCHEMA AS ` + "`schema`" + `,TABLE_NAME AS identity FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND TABLE_TYPE=? ORDER BY BINARY TABLE_NAME LIMIT 1001`, []any{r.Schema, strings.ToUpper(r.ObjectKind)}, nil
		case "function", "procedure":
			return `SELECT ROUTINE_NAME AS name,LOWER(ROUTINE_TYPE) AS kind,ROUTINE_SCHEMA AS ` + "`schema`" + `,ROUTINE_NAME AS identity FROM information_schema.ROUTINES WHERE BINARY ROUTINE_SCHEMA=BINARY ? AND ROUTINE_TYPE=? ORDER BY BINARY ROUTINE_NAME LIMIT 1001`, []any{r.Schema, strings.ToUpper(r.ObjectKind)}, nil
		case "trigger":
			return `SELECT TRIGGER_NAME AS name,'trigger' AS kind,TRIGGER_SCHEMA AS ` + "`schema`" + `,TRIGGER_NAME AS identity FROM information_schema.TRIGGERS WHERE BINARY TRIGGER_SCHEMA=BINARY ? ORDER BY BINARY TRIGGER_NAME LIMIT 1001`, []any{r.Schema}, nil
		}
	case "search":
		return `SELECT name,kind,` + "`schema`" + `,name AS identity FROM (SELECT TABLE_NAME AS name,CASE TABLE_TYPE WHEN 'VIEW' THEN 'view' WHEN 'SEQUENCE' THEN 'sequence' ELSE 'table' END AS kind,TABLE_SCHEMA AS ` + "`schema`" + ` FROM information_schema.TABLES UNION ALL SELECT ROUTINE_NAME,LOWER(ROUTINE_TYPE),ROUTINE_SCHEMA FROM information_schema.ROUTINES UNION ALL SELECT TRIGGER_NAME,'trigger',TRIGGER_SCHEMA FROM information_schema.TRIGGERS) objects WHERE LOCATE(LOWER(?),LOWER(name))>0 AND (?='' OR BINARY ` + "`schema`" + `=BINARY ?) ORDER BY BINARY ` + "`schema`" + `,kind,BINARY name LIMIT 1001`, []any{r.Search, r.Schema, r.Schema}, nil
	case "columns":
		return `SELECT c.COLUMN_NAME AS name,c.COLUMN_TYPE AS nativeType,IF(c.IS_NULLABLE='YES','true','false') AS nullable,c.COLUMN_DEFAULT AS ` + "`default`" + `,COALESCE(c.GENERATION_EXPRESSION,'') AS generated,COALESCE(k.ORDINAL_POSITION,0) AS primaryKey,IF((` + mariaDBColumnEditabilitySQL + `)='','true','false') AS editable,(` + mariaDBColumnEditabilitySQL + `) AS editReason,` + mariaDBColumnComparisonSQL + ` AS comparison FROM information_schema.COLUMNS c LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON BINARY k.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY k.TABLE_NAME=BINARY c.TABLE_NAME AND BINARY k.COLUMN_NAME=BINARY c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY' WHERE BINARY c.TABLE_SCHEMA=BINARY ? AND BINARY c.TABLE_NAME=BINARY ? ORDER BY c.ORDINAL_POSITION LIMIT 1001`, args, nil
	case "foreignKeys":
		return `SELECT CONSTRAINT_NAME AS name,REFERENCED_TABLE_SCHEMA AS targetSchema,REFERENCED_TABLE_NAME AS targetTable,COLUMN_NAME AS sourceColumn,REFERENCED_COLUMN_NAME AS targetColumn,ORDINAL_POSITION AS position FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY BINARY CONSTRAINT_NAME,ORDINAL_POSITION LIMIT 1001`, args, nil
	case "referencingTables":
		return `SELECT MIN(TABLE_SCHEMA) AS ` + "`schema`" + `,MIN(TABLE_NAME) AS name,'table' AS kind FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY REFERENCED_TABLE_SCHEMA=BINARY ? AND BINARY REFERENCED_TABLE_NAME=BINARY ? GROUP BY BINARY TABLE_SCHEMA,BINARY TABLE_NAME ORDER BY BINARY TABLE_SCHEMA,BINARY TABLE_NAME LIMIT 1001`, args, nil
	case "keys":
		return `SELECT MIN(CONSTRAINT_NAME) AS name,CASE WHEN MIN(CONSTRAINT_NAME)='PRIMARY' THEN 'primaryKey' WHEN MAX(REFERENCED_TABLE_NAME) IS NOT NULL THEN 'foreignKey' ELSE 'unique' END AS kind,CONCAT('(',GROUP_CONCAT(CONCAT('` + "`" + `',REPLACE(COLUMN_NAME,'` + "`" + `','` + "``" + `'),'` + "`" + `') ORDER BY ORDINAL_POSITION SEPARATOR ', '),')') AS definition FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? GROUP BY BINARY CONSTRAINT_NAME ORDER BY BINARY CONSTRAINT_NAME LIMIT 1001`, args, nil
	case "indexes":
		return `SELECT MIN(INDEX_NAME) AS name,IF(NON_UNIQUE=0,'unique','index') AS kind,CONCAT(INDEX_TYPE,' (',GROUP_CONCAT(CONCAT('` + "`" + `',REPLACE(COLUMN_NAME,'` + "`" + `','` + "``" + `'),'` + "`" + `',IF(SUB_PART IS NULL,'',CONCAT('(',SUB_PART,')')),IF(COLLATION='D',' DESC','')) ORDER BY SEQ_IN_INDEX SEPARATOR ', '),')',IF(IGNORED='YES',' IGNORED','')) AS definition FROM information_schema.STATISTICS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? GROUP BY BINARY INDEX_NAME,NON_UNIQUE,INDEX_TYPE,IGNORED ORDER BY BINARY INDEX_NAME LIMIT 1001`, args, nil
	case "constraints":
		return `SELECT MIN(tc.CONSTRAINT_NAME) AS name,tc.CONSTRAINT_TYPE AS kind,COALESCE(cc.CHECK_CLAUSE,GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', '),'') AS definition FROM information_schema.TABLE_CONSTRAINTS tc LEFT JOIN information_schema.CHECK_CONSTRAINTS cc ON BINARY cc.CONSTRAINT_SCHEMA=BINARY tc.CONSTRAINT_SCHEMA AND BINARY cc.CONSTRAINT_NAME=BINARY tc.CONSTRAINT_NAME AND BINARY cc.TABLE_NAME=BINARY tc.TABLE_NAME LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON BINARY k.CONSTRAINT_SCHEMA=BINARY tc.CONSTRAINT_SCHEMA AND BINARY k.CONSTRAINT_NAME=BINARY tc.CONSTRAINT_NAME AND BINARY k.TABLE_NAME=BINARY tc.TABLE_NAME WHERE BINARY tc.TABLE_SCHEMA=BINARY ? AND BINARY tc.TABLE_NAME=BINARY ? GROUP BY BINARY tc.CONSTRAINT_NAME,tc.CONSTRAINT_TYPE,cc.CHECK_CLAUSE ORDER BY BINARY tc.CONSTRAINT_NAME LIMIT 1001`, args, nil
	case "triggers":
		return `SELECT TRIGGER_NAME AS name,'trigger' AS kind,CONCAT(ACTION_TIMING,' ',EVENT_MANIPULATION,' ',ACTION_STATEMENT) AS definition FROM information_schema.TRIGGERS WHERE BINARY EVENT_OBJECT_SCHEMA=BINARY ? AND BINARY EVENT_OBJECT_TABLE=BINARY ? ORDER BY BINARY TRIGGER_NAME LIMIT 1001`, args, nil
	}
	return "", nil, errors.New("This MariaDB catalog operation is not implemented in the private stage.")
}
