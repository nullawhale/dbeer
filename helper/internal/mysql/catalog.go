package mysql

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

// QuoteIdentifier is the only path from an object name to SQL syntax. Metadata
// predicates use prepared parameters; server object names are never SQL text.
func QuoteIdentifier(name string) string { return "`" + strings.ReplaceAll(name, "`", "``") + "`" }

const primaryKeyQuery = `SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND CONSTRAINT_NAME = 'PRIMARY'
ORDER BY ORDINAL_POSITION LIMIT 1001`

func (session *Session) catalog(ctx context.Context, command protocol.Command, sinks ...adapter.ResultSink) protocol.Response {
	request := *command.Catalog
	if !request.Valid() {
		response := protocol.ErrorResponse(command, "validation", "Invalid MySQL catalog request.")
		response.Connected, response.TransactionStatus = !session.closed.Load(), session.TransactionStatus()
		return response
	}
	if request.IsPostgresTypeOperation() || request.ObjectKind == "type" {
		response := protocol.ErrorResponse(command, "unsupported", "PostgreSQL user-defined type operations are not supported by MySQL.")
		response.Connected, response.TransactionStatus = !session.closed.Load(), session.TransactionStatus()
		return response
	}
	var unavailable bool
	var metadataWarning bool
	var browseNotice, sourceSQL string
	response := session.executeWith(ctx, command, func(collector *collector, result *wire.Result) error {
		var err error
		switch request.Kind {
		case "definition":
			err = session.catalogDefinition(collector, request)
		case "name":
			err = session.catalogName(collector, request)
		case "foreignKeys":
			object, lookupErr := session.work.client.Execute(`SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=? LIMIT 1`, request.Schema, request.Object)
			if lookupErr != nil {
				return lookupErr
			}
			exists := object.RowNumber() == 1
			object.Close()
			if !exists {
				return &wire.MyError{Code: 1146, State: "42S02", Message: "object unavailable"}
			}
			query, args := catalogQuery(request)
			var loaded *wire.Result
			loaded, err = session.work.client.Execute(query, args...)
			if err == nil {
				defer loaded.Close()
				metadataWarning = loaded.Warnings > 0
				err = collectLoaded(collector, result, loaded)
			}
		case "select", "browse":
			err = session.catalogSelect(collector, result, request, &browseNotice, &sourceSQL)
		default:
			query, args := catalogQuery(request)
			var loaded *wire.Result
			loaded, err = session.work.client.Execute(query, args...)
			if err == nil {
				defer loaded.Close()
				metadataWarning = loaded.Warnings > 0
				if request.Kind == "objects" || request.Kind == "search" {
					// Normalize before collector delivery: a streamed row may be
					// serialized and acknowledged before executeWith returns.
					for _, row := range loaded.Values {
						if len(row) > 3 && row[0].Type != wire.FieldValueTypeNull {
							identity := catalogIdentity(string(row[0].AsString()))
							row[3] = wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(identity))
						}
					}
				}
				err = collectLoaded(collector, result, loaded)
			}
		}
		var server *wire.MyError
		if errors.As(err, &server) && (server.Code == 1049 || server.Code == 1146 || server.Code == 1305 || server.Code == 1360) {
			unavailable = true
		}
		return err
	}, sinks...)
	if unavailable && response.Connected && request.Kind != "browse" && request.Kind != "foreignKeys" {
		response.Type, response.Category, response.Message, response.SQLState = "query.result", "", "", ""
		response.Columns, response.Rows = nil, [][]*string{}
		response.RowCount, response.DisplayedRowCount = 0, 0
		response.DisplayNotice = "This object is no longer available. Refresh its catalog branch."
	} else if response.Type == "error" && response.Category == "sql" {
		response.Message = "Cannot load this MySQL catalog branch. Check object availability and permissions."
	}
	if response.Type == "query.result" && response.DisplayNotice == "" {
		if request.Kind == "browse" {
			response.DisplayNotice = browseNotice
		}
		if request.Kind == "definition" && len(response.Rows) == 0 {
			response.DisplayNotice = "The object definition is unavailable with the current permissions."
		}
		if (request.Kind == "columns" || request.Kind == "name") && len(response.Rows) == 0 {
			response.DisplayNotice = "This object is unavailable with the current permissions. Refresh its catalog branch."
		}
		if metadataWarning {
			response.DisplayNotice = "The server reported a metadata warning. Inspect the full object definition for complete details."
		}
	}

	if response.Type == "query.result" && request.Kind == "browse" {
		response = response.WithReadSQL(sourceSQL)
	}
	return response
}

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
	fields := make([]*wire.Field, len(names))
	for index, name := range names {
		fields[index] = &wire.Field{Name: []byte(name), Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45}
	}
	result := wire.NewResultReserveResultset(len(names))
	defer result.Close()
	result.Fields = fields
	if err := collector.columns(result); err != nil {
		return err
	}
	for _, row := range rows {
		values := make([]wire.FieldValue, len(row))
		for index, value := range row {
			if value == nil {
				values[index] = wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil)
			} else {
				values[index] = wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(*value))
			}
		}
		if err := collector.row(values); err != nil {
			return err
		}
	}
	return nil
}

func text(value string) *string { return &value }

func catalogIdentity(name string) string {
	if len(name) > 128 {
		digest := sha256.Sum256([]byte(name))
		return hex.EncodeToString(digest[:])
	}
	return name
}

func (session *Session) catalogName(collector *collector, request protocol.CatalogRequest) error {
	var query string
	var args []any
	switch request.ObjectKind {
	case "table", "view":
		kind := "BASE TABLE"
		if request.ObjectKind == "view" {
			kind = "VIEW"
		}
		query = `SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND TABLE_TYPE=? LIMIT 1`
		args = []any{request.Schema, request.Object, kind}
	case "function", "procedure":
		query = `SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_NAME=? AND ROUTINE_TYPE=? LIMIT 1`
		args = []any{request.Schema, request.Object, strings.ToUpper(request.ObjectKind)}
	case "trigger":
		query = `SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=? AND TRIGGER_NAME=? LIMIT 1`
		args = []any{request.Schema, request.Object}
	default:
		return errors.New("invalid catalog object kind")
	}
	loaded, err := session.work.client.Execute(query, args...)
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
		// Object identity follows the same bounded name/hash convention as the
		// objects response. Reject stale or mismatched identities before copying.
		identity := catalogIdentity(name)
		if request.Identity == "" || request.Identity == identity {
			rows = append(rows, []*string{text(QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(name))})
		}
	}
	return collectCatalogRows(collector, []string{"name"}, rows)
}

func (session *Session) catalogDefinition(collector *collector, request protocol.CatalogRequest) error {
	keyword := map[string]string{"table": "TABLE", "view": "VIEW", "function": "FUNCTION", "procedure": "PROCEDURE", "trigger": "TRIGGER"}[request.ObjectKind]
	if keyword == "" {
		return errors.New("invalid catalog object kind")
	}
	loaded, err := session.work.client.Execute("SHOW CREATE " + keyword + " " + QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Object))
	if err != nil {
		return err
	}
	defer loaded.Close()
	rows := [][]*string{}
	if loaded.RowNumber() > 0 {
		index := 1
		if request.ObjectKind == "function" || request.ObjectKind == "procedure" || request.ObjectKind == "trigger" {
			index = 2
		}
		definition, err := loaded.GetString(0, index)
		if err != nil {
			return err
		}
		if definition != "" {
			rows = append(rows, []*string{text(request.Object), text(definition)})
		}
	}
	return collectCatalogRows(collector, []string{"name", "definition"}, rows)
}

func (session *Session) catalogSelect(collector *collector, result *wire.Result, request protocol.CatalogRequest, notice, sourceSQL *string) error {
	// Validate the relation even when it has no primary key, distinguishing a
	// missing object from a legitimate view or a table without a key.
	object, err := session.work.client.Execute(`SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=? LIMIT 1`, request.Schema, request.Object)
	if err != nil {
		return err
	}
	exists := object.RowNumber() == 1
	object.Close()
	if !exists {
		return &wire.MyError{Code: 1146, State: "42S02", Message: "object unavailable"}
	}
	keys, err := session.work.client.Execute(primaryKeyQuery, request.Schema, request.Object)
	if err != nil {
		return err
	}
	var primaryKey []string
	for index := 0; index < keys.RowNumber(); index++ {
		name, err := keys.GetString(index, 0)
		if err != nil {
			keys.Close()
			return err
		}
		// GetString aliases pooled driver packet storage. The next metadata
		// query can reuse it after Close, before the browse plan is built.
		primaryKey = append(primaryKey, strings.Clone(name))
	}
	keys.Close()
	if request.Kind == "browse" && len(primaryKey) == 0 {
		*notice = "This object has no primary key. No stable page order is guaranteed, even when data is unchanged; rows may repeat or be skipped between pages."
	}
	columns, err := session.work.client.Execute(`SELECT COLUMN_NAME,DATA_TYPE,CHARACTER_SET_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION LIMIT 4097`, request.Schema, request.Object)
	if err != nil {
		return err
	}
	actual := map[string]string{}
	columnOrder := []string{}
	for index := 0; index < columns.RowNumber(); index++ {
		name, err := columns.GetString(index, 0)
		if err != nil {
			columns.Close()
			return err
		}
		kind, err := columns.GetString(index, 1)
		if err != nil {
			columns.Close()
			return err
		}
		charset, _ := columns.GetString(index, 2)
		if (kind == "enum" || kind == "set") && (charset == "" || charset == "binary") {
			kind += "Binary"
		}
		// Map keys, native types and projection order must also outlive the
		// result; later Prepare/streaming calls reuse its packet buffers.
		name, kind = strings.Clone(name), strings.Clone(kind)
		actual[name] = kind
		columnOrder = append(columnOrder, name)
	}
	columns.Close()
	plan, err := buildBrowsePlan(request, actual, primaryKey, columnOrder)
	if err != nil {
		return err
	}
	*sourceSQL = plan.sourceSQL
	if request.Kind == "select" {
		return collectCatalogRows(collector, []string{"sql", "name"}, [][]*string{{text(plan.sourceSQL), text(QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Object))}})
	}
	collector.hiddenStorageFields = len(plan.storageColumns)
	if len(plan.args) == 0 {
		return session.work.client.ExecuteSelectStreaming(plan.statement, result, collector.row, collector.columns)
	}
	statement, err := session.work.client.Prepare(plan.statement)
	if err != nil {
		return err
	}
	defer statement.Close()
	return statement.ExecuteSelectStreaming(result, collector.row, collector.columns, plan.args...)
}

func catalogQuery(request protocol.CatalogRequest) (string, []any) {
	args := []any{request.Schema, request.Object}
	switch request.Kind {
	case "completion":
		return `WITH objects AS (
SELECT TABLE_NAME AS name, IF(TABLE_TYPE='VIEW','view','table') AS kind, TABLE_SCHEMA AS ` + "`schema`" + ` FROM information_schema.TABLES
UNION ALL SELECT ROUTINE_NAME, 'function', ROUTINE_SCHEMA FROM information_schema.ROUTINES WHERE ROUTINE_TYPE='FUNCTION'
), page AS (
SELECT * FROM objects WHERE (?<>'' AND ` + "`schema`" + `=?) OR (?='' AND ` + "`schema`" + ` NOT IN ('information_schema','mysql','performance_schema','sys'))
ORDER BY ` + "`schema`" + `,name,kind LIMIT 200 OFFSET ?
)
SELECT name,kind,` + "`schema`" + `,COALESCE((SELECT JSON_ARRAYAGG(c.COLUMN_NAME) FROM information_schema.COLUMNS c
 WHERE c.TABLE_SCHEMA=page.` + "`schema`" + ` AND c.TABLE_NAME=page.name AND page.kind IN ('table','view')),JSON_ARRAY()) AS columns,
COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('name',fk.CONSTRAINT_NAME,'targetSchema',fk.UNIQUE_CONSTRAINT_SCHEMA,'targetTable',fk.REFERENCED_TABLE_NAME,
 'columns',(SELECT JSON_ARRAYAGG(JSON_OBJECT('source',k.COLUMN_NAME,'target',k.REFERENCED_COLUMN_NAME))
 FROM information_schema.KEY_COLUMN_USAGE k WHERE k.CONSTRAINT_SCHEMA=fk.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME=fk.CONSTRAINT_NAME AND k.TABLE_NAME=fk.TABLE_NAME)))
 FROM information_schema.REFERENTIAL_CONSTRAINTS fk WHERE fk.CONSTRAINT_SCHEMA=page.` + "`schema`" + ` AND fk.TABLE_NAME=page.name AND page.kind='table'),JSON_ARRAY()) AS foreignKeys,
COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('returnType',r.DTD_IDENTIFIER,'parameters',
 COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('name',COALESCE(p.PARAMETER_NAME,''),'type',p.DTD_IDENTIFIER,'position',p.ORDINAL_POSITION))
 FROM information_schema.PARAMETERS p WHERE p.SPECIFIC_SCHEMA=r.ROUTINE_SCHEMA AND p.SPECIFIC_NAME=r.SPECIFIC_NAME
 AND p.ORDINAL_POSITION>0 AND p.PARAMETER_MODE IN ('IN','INOUT')),JSON_ARRAY())))
 FROM information_schema.ROUTINES r WHERE page.kind='function' AND r.ROUTINE_SCHEMA=page.` + "`schema`" + ` AND r.ROUTINE_NAME=page.name AND r.ROUTINE_TYPE='FUNCTION'),JSON_ARRAY()) AS signatures,
COALESCE((SELECT JSON_OBJECTAGG(c.COLUMN_NAME,c.COLUMN_TYPE) FROM information_schema.COLUMNS c
 WHERE c.TABLE_SCHEMA=page.` + "`schema`" + ` AND c.TABLE_NAME=page.name AND page.kind IN ('table','view')),JSON_OBJECT()) AS columnTypes
FROM page ORDER BY ` + "`schema`" + `,name,kind`, []any{request.Schema, request.Schema, request.Schema, request.Page * 200}
	case "search":
		return `SELECT name,kind,` + "`schema`" + `,name AS identity FROM (
SELECT TABLE_NAME AS name,IF(TABLE_TYPE='VIEW','view','table') AS kind,TABLE_SCHEMA AS ` + "`schema`" + ` FROM information_schema.TABLES
UNION ALL SELECT ROUTINE_NAME AS name,LOWER(ROUTINE_TYPE) AS kind,ROUTINE_SCHEMA AS ` + "`schema`" + ` FROM information_schema.ROUTINES
UNION ALL SELECT TRIGGER_NAME AS name,'trigger' AS kind,TRIGGER_SCHEMA AS ` + "`schema`" + ` FROM information_schema.TRIGGERS
) catalog_objects WHERE LOCATE(LOWER(?),LOWER(name))>0 AND (?='' OR ` + "`schema`" + `=?) ORDER BY ` + "`schema`" + `,kind,name LIMIT 1001`, []any{request.Search, request.Schema, request.Schema}
	case "schemas":
		return `SELECT SCHEMA_NAME AS name, 'schema' AS kind FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME LIMIT 1001`, nil
	case "objects":
		switch request.ObjectKind {
		case "table", "view":
			kind := "BASE TABLE"
			if request.ObjectKind == "view" {
				kind = "VIEW"
			}
			return `SELECT TABLE_NAME AS name, IF(TABLE_TYPE='VIEW','view','table') AS kind, TABLE_SCHEMA AS ` + "`schema`" + `, TABLE_NAME AS identity FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_TYPE=? ORDER BY TABLE_NAME LIMIT 1001`, []any{request.Schema, kind}
		case "function", "procedure":
			return `SELECT ROUTINE_NAME AS name, LOWER(ROUTINE_TYPE) AS kind, ROUTINE_SCHEMA AS ` + "`schema`" + `, ROUTINE_NAME AS identity FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_TYPE=? ORDER BY ROUTINE_NAME LIMIT 1001`, []any{request.Schema, strings.ToUpper(request.ObjectKind)}
		case "trigger":
			return `SELECT TRIGGER_NAME AS name, 'trigger' AS kind, TRIGGER_SCHEMA AS ` + "`schema`" + `, TRIGGER_NAME AS identity FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=? ORDER BY TRIGGER_NAME LIMIT 1001`, []any{request.Schema}
		}
	case "columns":
		condition := `CASE WHEN t.TABLE_TYPE <> 'BASE TABLE' THEN 'Views are read-only.'
WHEN COALESCE(t.ENGINE,'') <> 'InnoDB' THEN 'Only InnoDB tables support data editing.'
WHEN NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS pk WHERE pk.TABLE_SCHEMA=c.TABLE_SCHEMA AND pk.TABLE_NAME=c.TABLE_NAME AND pk.CONSTRAINT_TYPE='PRIMARY KEY') THEN 'A primary key is required for data editing.'
WHEN COALESCE(c.GENERATION_EXPRESSION,'') <> '' THEN 'Generated columns are read-only.'
WHEN c.DATA_TYPE NOT IN ('tinyint','smallint','mediumint','int','bigint','decimal','numeric','float','double','bit','json','enum','set','geometry','point','linestring','polygon','multipoint','multilinestring','multipolygon','geometrycollection','geomcollection','vector','char','varchar','tinytext','text','mediumtext','longtext','binary','varbinary','tinyblob','blob','mediumblob','longblob','date','datetime','timestamp','time','year') THEN 'This native type is read-only.' ELSE '' END`
		return `SELECT c.COLUMN_NAME AS name, c.COLUMN_TYPE AS nativeType, IF(c.IS_NULLABLE='YES','true','false') AS nullable, c.COLUMN_DEFAULT AS ` + "`default`" + `, COALESCE(c.GENERATION_EXPRESSION,'') AS ` + "`generated`" + `, COALESCE(k.ORDINAL_POSITION,0) AS primaryKey, IF((` + condition + `)='','true','false') AS editable, (` + condition + `) AS editReason
FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON t.TABLE_SCHEMA=c.TABLE_SCHEMA AND t.TABLE_NAME=c.TABLE_NAME
LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON k.TABLE_SCHEMA=c.TABLE_SCHEMA AND k.TABLE_NAME=c.TABLE_NAME AND k.COLUMN_NAME=c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY'
WHERE c.TABLE_SCHEMA=? AND c.TABLE_NAME=? ORDER BY c.ORDINAL_POSITION LIMIT 1001`, args
	case "foreignKeys":
		return `SELECT k.CONSTRAINT_NAME AS name, k.REFERENCED_TABLE_SCHEMA AS targetSchema, k.REFERENCED_TABLE_NAME AS targetTable,
k.COLUMN_NAME AS sourceColumn, k.REFERENCED_COLUMN_NAME AS targetColumn, k.ORDINAL_POSITION AS position
FROM information_schema.KEY_COLUMN_USAGE k WHERE k.TABLE_SCHEMA=? AND k.TABLE_NAME=? AND k.REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY k.CONSTRAINT_NAME,k.ORDINAL_POSITION LIMIT 1001`, args
	case "keys":
		return `SELECT k.CONSTRAINT_NAME AS name, CASE WHEN k.CONSTRAINT_NAME='PRIMARY' THEN 'primaryKey' WHEN MAX(k.REFERENCED_TABLE_NAME) IS NOT NULL THEN 'foreignKey' ELSE 'unique' END AS kind,
CONCAT('(',GROUP_CONCAT(CONCAT('` + "`" + `',REPLACE(k.COLUMN_NAME,'` + "`" + `','` + "``" + `'),'` + "`" + `') ORDER BY k.ORDINAL_POSITION SEPARATOR ', '),')',
CASE WHEN MAX(k.REFERENCED_TABLE_NAME) IS NOT NULL THEN CONCAT(' REFERENCES ',MAX(k.REFERENCED_TABLE_SCHEMA),'.',MAX(k.REFERENCED_TABLE_NAME),' (',GROUP_CONCAT(k.REFERENCED_COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', '),')') ELSE '' END) AS definition
FROM information_schema.KEY_COLUMN_USAGE k WHERE k.TABLE_SCHEMA=? AND k.TABLE_NAME=? GROUP BY k.CONSTRAINT_NAME ORDER BY k.CONSTRAINT_NAME LIMIT 1001`, args
	case "indexes":
		return `SELECT INDEX_NAME AS name, IF(NON_UNIQUE=0,'unique','index') AS kind,
CONCAT(INDEX_TYPE,' (',GROUP_CONCAT(CONCAT(COALESCE(CONCAT('` + "`" + `',REPLACE(COLUMN_NAME,'` + "`" + `','` + "``" + `'),'` + "`" + `'),CONCAT('(',EXPRESSION,')')),IF(SUB_PART IS NULL,'',CONCAT('(',SUB_PART,')')),IF(COLLATION='D',' DESC','')) ORDER BY SEQ_IN_INDEX SEPARATOR ', '),')') AS definition
FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? GROUP BY INDEX_NAME,NON_UNIQUE,INDEX_TYPE ORDER BY INDEX_NAME LIMIT 1001`, args
	case "constraints":
		return `SELECT tc.CONSTRAINT_NAME AS name, tc.CONSTRAINT_TYPE AS kind,
COALESCE(cc.CHECK_CLAUSE,GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ', '),'') AS definition
FROM information_schema.TABLE_CONSTRAINTS tc LEFT JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME
LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON k.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME=tc.CONSTRAINT_NAME AND k.TABLE_NAME=tc.TABLE_NAME
WHERE tc.TABLE_SCHEMA=? AND tc.TABLE_NAME=? GROUP BY tc.CONSTRAINT_NAME,tc.CONSTRAINT_TYPE,cc.CHECK_CLAUSE ORDER BY tc.CONSTRAINT_NAME LIMIT 1001`, args
	case "triggers":
		return `SELECT TRIGGER_NAME AS name, 'trigger' AS kind, CONCAT(ACTION_TIMING,' ',EVENT_MANIPULATION,' ',ACTION_STATEMENT) AS definition FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA=? AND EVENT_OBJECT_TABLE=? ORDER BY TRIGGER_NAME LIMIT 1001`, args
	}
	return "SELECT 1 WHERE FALSE", nil
}
