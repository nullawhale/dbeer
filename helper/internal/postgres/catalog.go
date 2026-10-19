package postgres

import (
	"context"
	"fmt"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// Identifiers in generated SQL use pgx's PostgreSQL quoting. All metadata
// predicates use server parameters, including names containing quotes or SQL.
func catalog(ctx context.Context, conn *pgx.Conn, command protocol.Command) protocol.Response {
	return catalogWithSink(ctx, conn, command, nil)
}

func catalogWithSink(ctx context.Context, conn *pgx.Conn, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	if command.Catalog == nil || !command.Catalog.Valid() {
		response := protocol.ErrorResponse(command, "protocol", "Invalid catalog request.")
		response.Connected, response.TransactionStatus = true, transactionStatus(conn)
		return response
	}
	request := *command.Catalog
	if failure := catalogAccess(ctx, conn, command, request); failure != nil {
		return *failure
	}
	sql, values, notice := catalogSQL(request)
	if request.Kind == "browse" {
		var failure *protocol.Response
		sql, values, notice, failure = browseSQL(ctx, conn, command)
		if failure != nil {
			return *failure
		}
	}
	response := executeParamsSink(ctx, conn, command, sql, values, sink)
	if response.Type == "error" && response.Category == "sql" {
		response.Message = "Catalog information is unavailable or access was denied."
		response.ErrorPosition = 0
	}
	if response.Type == "query.result" {
		if notice != "" {
			response.DisplayNotice = notice
		} else if len(response.Rows) == 0 && request.Kind != "schemas" && request.Kind != "objects" && request.Kind != "search" && request.Kind != "browse" {
			response.DisplayNotice = "No catalog information is available for this object."
		}
	}
	return response
}

func catalogAccess(ctx context.Context, conn *pgx.Conn, command protocol.Command, request protocol.CatalogRequest) *protocol.Response {
	if request.Kind == "schemas" || request.Kind == "search" || request.Kind == "completion" {
		return nil
	}
	checks := []struct {
		sql    string
		values [][]byte
	}{
		{`SELECT has_schema_privilege(n.oid,'USAGE') FROM pg_catalog.pg_namespace n WHERE n.nspname::text=$1::text`, [][]byte{[]byte(request.Schema)}},
	}
	if request.Object != "" && (request.ObjectKind == "table" || request.ObjectKind == "view" || request.ObjectKind == "") {
		checks = append(checks, struct {
			sql    string
			values [][]byte
		}{
			`SELECT (has_table_privilege(c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege(c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname::text=$1::text AND c.relname::text=$2::text AND c.relkind IN ('r','p','f','v','m')`,
			[][]byte{[]byte(request.Schema), []byte(request.Object)},
		})
	}
	for _, check := range checks {
		response := executeParams(ctx, conn, command, check.sql, check.values)
		if response.Type == "error" {
			if response.Category == "sql" {
				response.Message = "Catalog information is unavailable or access was denied."
				response.ErrorPosition = 0
			}
			return &response
		}
		if len(response.Rows) == 0 || len(response.Rows[0]) == 0 || response.Rows[0][0] == nil || *response.Rows[0][0] != "t" {
			failure := protocol.ErrorResponse(command, "sql", "Catalog information is unavailable or access was denied.")
			failure.SQLState = "42501"
			failure.Connected, failure.TransactionStatus = true, transactionStatus(conn)
			return &failure
		}
	}
	return nil
}

const relationAccess = `has_schema_privilege(n.oid, 'USAGE') AND
 (has_table_privilege(c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
 has_any_column_privilege(c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'))`

const relationWhere = ` FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text AND ` + relationAccess

func catalogSQL(request protocol.CatalogRequest) (string, [][]byte, string) {
	params := func(values ...string) [][]byte {
		result := make([][]byte, len(values))
		for index, value := range values {
			result[index] = []byte(value)
		}
		return result
	}
	objectParams := params(request.Schema, request.Object)
	switch request.Kind {
	case "completion":
		// Load names in batches, without inspecting table data or generating
		// one metadata request per relation. System schemas remain available
		// through explicit catalog browsing or a schema-scoped request.
		return `WITH objects AS (
SELECT c.relname::text AS name, CASE WHEN c.relkind IN ('v','m') THEN 'view' ELSE 'table' END AS kind,
 n.nspname::text AS schema, c.oid AS relation
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p','f','v','m') AND ` + relationAccess + `
UNION ALL
SELECT DISTINCT p.proname::text, 'function', n.nspname::text, 0::oid
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE p.prokind IN ('f','a','w') AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')
), page AS (
SELECT * FROM objects WHERE ($1::text<>'' AND schema=$1::text) OR ($1::text='' AND schema NOT IN ('pg_catalog','information_schema')
 AND schema NOT LIKE 'pg_toast%' AND schema NOT LIKE 'pg_temp_%')
ORDER BY schema,name,kind LIMIT 200 OFFSET ($2::int * 200)
)
SELECT name,kind,schema,COALESCE((SELECT json_agg(a.attname::text ORDER BY a.attnum)
 FROM pg_catalog.pg_attribute a WHERE a.attrelid=page.relation AND a.attnum>0 AND NOT a.attisdropped),'[]'::json)::text AS columns,
COALESCE((SELECT json_agg(json_build_object('name',k.conname::text,'targetSchema',n.nspname::text,'targetTable',c.relname::text,
 'columns',(SELECT json_agg(json_build_object('source',sa.attname::text,'target',ta.attname::text) ORDER BY pair.ordinality)
 FROM unnest(k.conkey,k.confkey) WITH ORDINALITY pair(source,target,ordinality)
 JOIN pg_catalog.pg_attribute sa ON sa.attrelid=k.conrelid AND sa.attnum=pair.source
 JOIN pg_catalog.pg_attribute ta ON ta.attrelid=k.confrelid AND ta.attnum=pair.target)) ORDER BY k.conname)
 FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_class c ON c.oid=k.confrelid
 JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE k.contype='f' AND k.conrelid=page.relation AND ` + relationAccess + `),'[]'::json)::text AS "foreignKeys",
COALESCE((SELECT json_agg(overloads.signature ORDER BY overloads.oid) FROM (
 SELECT p.oid,json_build_object('returnType',pg_catalog.pg_get_function_result(p.oid),'parameters',
 COALESCE((SELECT json_agg(json_build_object('name',COALESCE(args.name,''),'type',pg_catalog.format_type(args.type,NULL),
 'position',args.position,'optional',args.position>p.pronargs-p.pronargdefaults,'variadic',args.mode='v') ORDER BY args.position)
 FROM (SELECT arg.type,p.proargnames[arg.ordinality] AS name,COALESCE(p.proargmodes[arg.ordinality]::text,'i') AS mode,
 row_number() OVER (ORDER BY arg.ordinality) AS position
 FROM unnest(COALESCE(p.proallargtypes,p.proargtypes::oid[])) WITH ORDINALITY arg(type,ordinality)
 WHERE COALESCE(p.proargmodes[arg.ordinality]::text,'i') IN ('i','b','v')) args),'[]'::json)) AS signature
 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
 WHERE page.kind='function' AND p.proname::text=page.name AND n.nspname::text=page.schema AND p.prokind IN ('f','a','w')
 AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')
 ORDER BY p.oid LIMIT 32) overloads),'[]'::json)::text AS signatures
FROM page ORDER BY schema,name,kind`, params(request.Schema, fmt.Sprint(request.Page)), ""
	case "schemas":
		return `SELECT nspname::text AS name, 'schema'::text AS kind FROM pg_catalog.pg_namespace
WHERE nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp_%' AND has_schema_privilege(oid, 'USAGE') ORDER BY name`, nil, ""
	case "search":
		// Catalog names retain C collation after ::text; fold both operands
		// with the database collation so non-ASCII case handling agrees.
		return `SELECT name,kind,schema,identity FROM (` + searchableObjects + `) objects
WHERE strpos(lower(name COLLATE pg_catalog."default"),lower($1::text COLLATE pg_catalog."default"))>0 AND ($2::text='' OR schema=$2::text)
ORDER BY schema,name,kind,identity`, params(request.Search, request.Schema), ""
	case "objects":
		switch request.ObjectKind {
		case "table", "view":
			kinds := "('r','p','f')"
			if request.ObjectKind == "view" {
				kinds = "('v','m')"
			}
			return `SELECT c.relname::text AS name, $2::text AS kind, n.nspname::text AS schema, c.oid::text AS identity
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND c.relkind IN ` + kinds + ` AND ` + relationAccess + ` ORDER BY name,identity`, params(request.Schema, request.ObjectKind), ""
		case "function", "procedure":
			kind := "('f','w')"
			if request.ObjectKind == "procedure" {
				kind = "('p')"
			}
			return `SELECT p.proname::text AS name, $2::text AS kind, n.nspname::text AS schema, p.oid::text AS identity
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname::text=$1::text AND p.prokind IN ` + kind + ` AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE') ORDER BY name,identity`, params(request.Schema, request.ObjectKind), ""
		case "trigger":
			return `SELECT t.tgname::text AS name, 'trigger'::text AS kind, n.nspname::text AS schema, t.oid::text AS identity
FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND NOT t.tgisinternal AND ` + relationAccess + ` ORDER BY name,identity`, params(request.Schema), ""
		}
	case "columns":
		return `SELECT a.attname::text AS name, pg_catalog.format_type(a.atttypid,a.atttypmod)::text AS "nativeType",
CASE WHEN a.attnotnull THEN 'false' ELSE 'true' END AS nullable,
CASE WHEN a.attgenerated='' THEN pg_catalog.pg_get_expr(d.adbin,d.adrelid) ELSE NULL END AS "default",
CASE WHEN a.attgenerated<>'' THEN pg_catalog.pg_get_expr(d.adbin,d.adrelid)
 WHEN a.attidentity='a' THEN 'identity always' WHEN a.attidentity='d' THEN 'identity by default' ELSE '' END AS generated,
COALESCE((SELECT key.ordinality FROM pg_catalog.pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY key(attnum,ordinality)
 WHERE i.indrelid=c.oid AND i.indisprimary AND key.ordinality<=i.indnkeyatts AND key.attnum=a.attnum),0)::text AS "primaryKey",
CASE WHEN c.relkind IN ('r','p') AND a.attgenerated='' AND a.attidentity<>'a' AND has_column_privilege(c.oid,a.attnum,'UPDATE')
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_attribute unsupported WHERE unsupported.attrelid=c.oid AND unsupported.attnum>0
 AND NOT unsupported.attisdropped AND unsupported.atttypid NOT IN (` + editablePostgresTypeOIDs + `))
 AND EXISTS(SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid=c.oid AND i.indisprimary) THEN 'true' ELSE 'false' END AS editable,
CASE WHEN c.relkind NOT IN ('r','p') THEN 'Only base tables support data editing.'
 WHEN NOT EXISTS(SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid=c.oid AND i.indisprimary) THEN 'The table has no primary key.'
 WHEN EXISTS(SELECT 1 FROM pg_catalog.pg_attribute unsupported WHERE unsupported.attrelid=c.oid AND unsupported.attnum>0
 AND NOT unsupported.attisdropped AND unsupported.atttypid NOT IN (` + editablePostgresTypeOIDs + `)) THEN 'This table contains an unsupported type.'
 WHEN a.attgenerated<>'' OR a.attidentity='a' THEN 'The server generates this value.'
 WHEN NOT has_column_privilege(c.oid,a.attnum,'UPDATE') THEN 'UPDATE privilege is unavailable.' ELSE '' END AS "editReason"
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text AND c.relkind IN ('r','p','f','v','m') AND ` + relationAccess + ` ORDER BY a.attnum`, objectParams, ""
	case "keys", "constraints":
		filter := ""
		if request.Kind == "keys" {
			filter = " AND k.contype IN ('p','u','f')"
		}
		return `SELECT k.conname::text AS name,
CASE k.contype WHEN 'p' THEN 'primaryKey' WHEN 'f' THEN 'foreignKey' WHEN 'u' THEN 'unique' WHEN 'c' THEN 'check' WHEN 'x' THEN 'exclusion' ELSE k.contype::text END AS kind,
pg_catalog.pg_get_constraintdef(k.oid,true)::text AS definition
FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_class c ON c.oid=k.conrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text AND ` + relationAccess + filter + ` ORDER BY name`, objectParams, ""
	case "indexes":
		return `SELECT idx.relname::text AS name, CASE WHEN i.indisprimary THEN 'primaryKey' WHEN i.indisunique THEN 'unique' ELSE 'index' END AS kind,
pg_catalog.pg_get_indexdef(i.indexrelid)::text AS definition
FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class idx ON idx.oid=i.indexrelid JOIN pg_catalog.pg_class c ON c.oid=i.indrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text AND ` + relationAccess + ` ORDER BY name`, objectParams, ""
	case "triggers":
		return `SELECT t.tgname::text AS name, 'trigger'::text AS kind, pg_catalog.pg_get_triggerdef(t.oid,true)::text AS definition
FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text AND NOT t.tgisinternal AND ` + relationAccess + ` ORDER BY name`, objectParams, ""
	case "definition":
		switch request.ObjectKind {
		case "view":
			return `SELECT c.relname::text AS name, pg_catalog.pg_get_viewdef(c.oid,true)::text AS definition` + relationWhere + ` AND c.relkind IN ('v','m') AND ($3::text='' OR c.oid::text=$3::text)`, params(request.Schema, request.Object, request.Identity), ""
		case "table":
			return `SELECT c.relname::text AS name, NULL::text AS definition` + relationWhere + ` AND c.relkind IN ('r','p','f') AND ($3::text='' OR c.oid::text=$3::text)`, params(request.Schema, request.Object, request.Identity), "PostgreSQL table structure is available in Columns, Keys, Indexes, and Constraints. A single CREATE TABLE definition is unavailable."
		case "function", "procedure":
			kind := "('f','w')"
			if request.ObjectKind == "procedure" {
				kind = "('p')"
			}
			return `SELECT p.proname::text AS name, pg_catalog.pg_get_functiondef(p.oid)::text AS definition
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname::text=$1::text AND p.proname::text=$2::text AND ($3::text='' OR p.oid::text=$3::text)
AND p.prokind IN ` + kind + ` AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE') ORDER BY p.oid`, params(request.Schema, request.Object, request.Identity), ""
		case "trigger":
			return `SELECT t.tgname::text AS name, pg_catalog.pg_get_triggerdef(t.oid,true)::text AS definition
FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND t.tgname::text=$2::text AND ($3::text='' OR t.oid::text=$3::text) AND NOT t.tgisinternal AND ` + relationAccess + ` ORDER BY t.oid`, params(request.Schema, request.Object, request.Identity), ""
		}
	case "name":
		quoted := pgx.Identifier{request.Schema, request.Object}.Sanitize()
		switch request.ObjectKind {
		case "table", "view":
			kinds := "('r','p','f')"
			if request.ObjectKind == "view" {
				kinds = "('v','m')"
			}
			return `SELECT $3::text AS name` + relationWhere + ` AND c.relkind IN ` + kinds, params(request.Schema, request.Object, quoted), ""
		case "function", "procedure":
			kinds := "('f','w')"
			if request.ObjectKind == "procedure" {
				kinds = "('p')"
			}
			return `SELECT DISTINCT $4::text AS name
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname::text=$1::text AND p.proname::text=$2::text AND ($3::text='' OR p.oid::text=$3::text)
AND p.prokind IN ` + kinds + ` AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')`, params(request.Schema, request.Object, request.Identity, quoted), ""
		case "trigger":
			return `SELECT DISTINCT $4::text AS name
FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname::text=$1::text AND t.tgname::text=$2::text AND ($3::text='' OR t.oid::text=$3::text) AND NOT t.tgisinternal AND ` + relationAccess, params(request.Schema, request.Object, request.Identity, pgx.Identifier{request.Object}.Sanitize()), ""
		}
	case "select":
		quoted := pgx.Identifier{request.Schema, request.Object}.Sanitize()
		return `SELECT $3::text AS sql, $4::text AS name` + relationWhere + ` AND c.relkind IN ('r','p','f','v','m')`, params(request.Schema, request.Object, "SELECT * FROM "+quoted+" LIMIT 200", quoted), ""
	case "browse":
		return "SELECT * FROM " + pgx.Identifier{request.Schema, request.Object}.Sanitize() + " LIMIT 200", nil, ""
	}
	// Validation rejects unknown operations before this function is reached.
	return "SELECT NULL::text WHERE false", nil, ""
}

const searchableObjects = `SELECT c.relname::text AS name,CASE WHEN c.relkind IN ('v','m') THEN 'view' ELSE 'table' END::text AS kind,
n.nspname::text AS schema,c.oid::text AS identity
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p','f','v','m') AND ` + relationAccess + `
UNION ALL
SELECT p.proname::text,CASE WHEN p.prokind='p' THEN 'procedure' ELSE 'function' END::text,n.nspname::text,p.oid::text
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
WHERE p.prokind IN ('f','w','p') AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')
UNION ALL
SELECT t.tgname::text,'trigger'::text,n.nspname::text,t.oid::text
FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal AND ` + relationAccess
