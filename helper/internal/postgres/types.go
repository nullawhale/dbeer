package postgres

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

const typeKindSQL = `CASE t.typtype WHEN 'e' THEN 'enum' WHEN 'd' THEN 'domain' WHEN 'c' THEN 'composite'
WHEN 'r' THEN 'range' WHEN 'm' THEN 'multirange' ELSE 'base' END::text`

// A true array is identified through its element type's typarray link, not
// through its name or typelem (which also describes non-array base types).
const visibleTypeSQL = `t.typisdefined AND t.typtype IN ('e','d','c','r','m','b')
AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'
AND n.nspname NOT LIKE 'pg_temp_%' AND NOT pg_catalog.pg_is_other_temp_schema(n.oid)
AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_type element WHERE element.typarray=t.oid)
AND (t.typtype<>'c' OR EXISTS(SELECT 1 FROM pg_catalog.pg_class rowtype WHERE rowtype.oid=t.typrelid AND rowtype.relkind='c'))
AND pg_catalog.has_schema_privilege(n.oid,'USAGE') AND pg_catalog.has_type_privilege(t.oid,'USAGE')`

// TypeMetadata retains normalized catalog properties rather than parsing the
// displayed definition. OIDs in this structure belong only to this connection.
type TypeMetadata struct {
	OID               uint32
	Schema            string
	Name              string
	Kind              string
	Owner             string
	OwnerAvailable    bool
	Extension         string
	RelationOID       uint32
	BaseTypeOID       uint32
	BaseTypeModifier  int32
	BaseType          string
	Default           *string
	NotNull           bool
	Collation         string
	EnumValues        []TypeEnumValue
	Attributes        []TypeAttribute
	DomainConstraints []TypeConstraint
	Range             *TypeRange
	Base              *TypeBase
	MembersComplete   bool
}

type TypeEnumValue struct {
	Label     string
	Position  int
	SortOrder string
}

type TypeAttribute struct {
	Name         string
	NativeType   string
	TypeOID      uint32
	TypeModifier int32
	Collation    string
	NotNull      bool
	Position     int
}

type TypeConstraint struct {
	Name       string
	Definition string
	Validated  bool
}

type TypeRange struct {
	SubtypeOID     uint32
	Subtype        string
	Opclass        string
	Collation      string
	Canonical      string
	SubtypeDiff    string
	RangeName      string
	MultirangeName string
}

type TypeBase struct {
	Input, Output, Receive, Send, TypeModifierInput, TypeModifierOutput, Analyze, Subscript string
	Length                                                                                  int
	ByValue                                                                                 bool
	Alignment, Storage, Category, Delimiter                                                 string
	Preferred                                                                               bool
	ElementOID, ArrayOID                                                                    uint32
}

const typeHeaderSQL = `SELECT t.oid::text AS identity,n.nspname::text AS schema,t.typname::text AS name,
` + typeKindSQL + ` AS "typeKind",pg_catalog.pg_get_userbyid(t.typowner)::text AS owner,
pg_catalog.pg_has_role(t.typowner,'USAGE')::text AS "ownerAvailable",
COALESCE((SELECT e.extname::text FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_extension e ON e.oid=d.refobjid
 WHERE d.classid='pg_catalog.pg_type'::regclass AND d.objid=t.oid AND d.objsubid=0
 AND d.refclassid='pg_catalog.pg_extension'::regclass AND d.deptype='e' LIMIT 1),'')::text AS extension,
t.typrelid::text AS "relationOID",t.typbasetype::text AS "baseTypeOID",t.typtypmod::text AS "baseTypeModifier",
CASE WHEN t.typbasetype<>0 THEN pg_catalog.format_type(t.typbasetype,t.typtypmod) ELSE '' END::text AS "baseType",
CASE WHEN t.typdefaultbin IS NOT NULL THEN pg_catalog.pg_get_expr(t.typdefaultbin,0) ELSE t.typdefault END::text AS "default",
t.typnotnull::text AS "notNull",COALESCE(pg_catalog.quote_ident(cn.nspname)||'.'||pg_catalog.quote_ident(co.collname),'')::text AS collation
FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace
LEFT JOIN pg_catalog.pg_collation co ON co.oid=t.typcollation LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=co.collnamespace
WHERE t.oid::text=$3::text AND n.nspname::text=$1::text AND t.typname::text=$2::text
AND CASE WHEN $4::text='enum' THEN t.typtype='e' ELSE t.typtype<>'e' END AND ` + visibleTypeSQL

func typeParams(values ...string) [][]byte {
	result := make([][]byte, len(values))
	for index, value := range values {
		result[index] = []byte(value)
	}
	return result
}

func typeFailure(conn *pgx.Conn, command protocol.Command, category, message string) protocol.Response {
	failure := protocol.ErrorResponse(command, category, message)
	failure.Connected, failure.TransactionStatus = !conn.IsClosed(), transactionStatus(conn)
	return failure
}

func typeRead(ctx context.Context, conn *pgx.Conn, command protocol.Command, sql string, params [][]byte) protocol.Response {
	response := executeParams(ctx, conn, command, sql, params)
	if response.Type == "error" && response.Category == "sql" {
		response.Message, response.ErrorPosition = "Type metadata is unavailable or access was denied. Refresh the catalog.", 0
	}
	return response
}

func typeHeader(ctx context.Context, conn *pgx.Conn, command protocol.Command) (TypeMetadata, *protocol.Response) {
	var metadata TypeMetadata
	request := *command.Catalog
	if !protocol.ValidLocalTypeOID(request.Identity) || len(request.Schema) > 63 || len(request.Object) > 63 {
		failure := typeFailure(conn, command, "protocol", "A valid connection-local type identity is required. Refresh the catalog.")
		return metadata, &failure
	}
	response := typeRead(ctx, conn, command, typeHeaderSQL, typeParams(request.Schema, request.Object, request.Identity, request.ObjectKind))
	if response.Type == "error" {
		return metadata, &response
	}
	if response.Truncated || len(response.Rows) != 1 || len(response.Rows[0]) != 14 {
		failure := typeFailure(conn, command, "sql", "The type changed, is unavailable, or access was denied. Refresh the catalog.")
		failure.SQLState = "42704"
		return metadata, &failure
	}
	row := response.Rows[0]
	for index, value := range row {
		if index != 11 && value == nil {
			failure := typeFailure(conn, command, "result", "Type metadata is incomplete. Refresh the catalog.")
			return metadata, &failure
		}
	}
	metadata.OID = parseTypeOID(*row[0])
	metadata.Schema, metadata.Name, metadata.Kind, metadata.Owner = *row[1], *row[2], *row[3], *row[4]
	metadata.OwnerAvailable, metadata.Extension = *row[5] == "true", *row[6]
	metadata.RelationOID, metadata.BaseTypeOID = parseTypeOID(*row[7]), parseTypeOID(*row[8])
	modifier, _ := strconv.ParseInt(*row[9], 10, 32)
	metadata.BaseTypeModifier, metadata.BaseType = int32(modifier), *row[10]
	metadata.Default, metadata.NotNull, metadata.Collation = row[11], *row[12] == "true", *row[13]
	metadata.MembersComplete = true
	return metadata, nil
}

func parseTypeOID(value string) uint32 {
	parsed, _ := strconv.ParseUint(value, 10, 32)
	return uint32(parsed)
}

const enumValuesSQL = `SELECT e.enumlabel::text AS label,row_number() OVER (ORDER BY e.enumsortorder)::text AS position,
e.enumsortorder::text AS "sortOrder" FROM pg_catalog.pg_enum e WHERE e.enumtypid::text=$1::text ORDER BY e.enumsortorder`

// Member queries use a sentinel row beyond the display bound. Truncation is
// retained as unknown completeness; a prefix never becomes complete CREATE SQL.
func typeMembers(ctx context.Context, conn *pgx.Conn, command protocol.Command, metadata *TypeMetadata) *protocol.Response {
	var sql string
	identity := strconv.FormatUint(uint64(metadata.OID), 10)
	switch metadata.Kind {
	case "enum":
		sql = enumValuesSQL + ` LIMIT 1001`
	case "composite":
		identity = strconv.FormatUint(uint64(metadata.RelationOID), 10)
		sql = `SELECT a.attname::text,pg_catalog.format_type(a.atttypid,a.atttypmod)::text,a.atttypid::text,a.atttypmod::text,
CASE WHEN a.attcollation<>0 AND a.attcollation<>at.typcollation THEN pg_catalog.quote_ident(cn.nspname)||'.'||pg_catalog.quote_ident(co.collname) ELSE '' END::text,
a.attnotnull::text,a.attnum::text
FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type at ON at.oid=a.atttypid
LEFT JOIN pg_catalog.pg_collation co ON co.oid=a.attcollation LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=co.collnamespace
WHERE a.attrelid::text=$1::text AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum LIMIT 1001`
	case "domain":
		sql = `SELECT c.conname::text,pg_catalog.pg_get_constraintdef(c.oid,true)::text,c.convalidated::text
FROM pg_catalog.pg_constraint c WHERE c.contypid::text=$1::text ORDER BY c.conname,c.oid LIMIT 1001`
	case "range", "multirange":
		sql = `SELECT r.rngsubtype::text,pg_catalog.format_type(r.rngsubtype,NULL)::text,
pg_catalog.quote_ident(onsp.nspname)||'.'||pg_catalog.quote_ident(op.opcname),
COALESCE(pg_catalog.quote_ident(cn.nspname)||'.'||pg_catalog.quote_ident(co.collname),''),
CASE WHEN r.rngcanonical=0 THEN '' ELSE r.rngcanonical::regprocedure::text END,
CASE WHEN r.rngsubdiff=0 THEN '' ELSE r.rngsubdiff::regprocedure::text END,
pg_catalog.quote_ident(rn.nspname)||'.'||pg_catalog.quote_ident(rt.typname),
pg_catalog.quote_ident(mn.nspname)||'.'||pg_catalog.quote_ident(mt.typname)
FROM pg_catalog.pg_range r JOIN pg_catalog.pg_opclass op ON op.oid=r.rngsubopc JOIN pg_catalog.pg_namespace onsp ON onsp.oid=op.opcnamespace
JOIN pg_catalog.pg_type rt ON rt.oid=r.rngtypid JOIN pg_catalog.pg_namespace rn ON rn.oid=rt.typnamespace
JOIN pg_catalog.pg_type mt ON mt.oid=r.rngmultitypid JOIN pg_catalog.pg_namespace mn ON mn.oid=mt.typnamespace
LEFT JOIN pg_catalog.pg_collation co ON co.oid=r.rngcollation LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=co.collnamespace
WHERE r.rngtypid::text=$1::text OR r.rngmultitypid::text=$1::text`
	case "base":
		sql = `SELECT typinput::regproc::text,typoutput::regproc::text,typreceive::regproc::text,typsend::regproc::text,
typmodin::regproc::text,typmodout::regproc::text,typanalyze::regproc::text,typsubscript::regproc::text,
typlen::text,typbyval::text,typalign::text,typstorage::text,typcategory::text,typdelim::text,typispreferred::text,typelem::text,typarray::text
FROM pg_catalog.pg_type WHERE oid::text=$1::text`
	default:
		return nil
	}
	response := typeRead(ctx, conn, command, sql, typeParams(identity))
	if response.Type == "error" {
		return &response
	}
	metadata.MembersComplete = !response.Truncated
	for _, row := range response.Rows {
		for _, value := range row {
			if value == nil {
				failure := typeFailure(conn, command, "result", "Type properties are incomplete or inaccessible.")
				return &failure
			}
		}
		switch metadata.Kind {
		case "enum":
			position, _ := strconv.Atoi(*row[1])
			metadata.EnumValues = append(metadata.EnumValues, TypeEnumValue{Label: *row[0], Position: position, SortOrder: *row[2]})
		case "composite":
			modifier, _ := strconv.ParseInt(*row[3], 10, 32)
			position, _ := strconv.Atoi(*row[6])
			metadata.Attributes = append(metadata.Attributes, TypeAttribute{Name: *row[0], NativeType: *row[1], TypeOID: parseTypeOID(*row[2]), TypeModifier: int32(modifier), Collation: *row[4], NotNull: *row[5] == "true", Position: position})
		case "domain":
			metadata.DomainConstraints = append(metadata.DomainConstraints, TypeConstraint{Name: *row[0], Definition: *row[1], Validated: *row[2] == "true"})
		case "range", "multirange":
			metadata.Range = &TypeRange{SubtypeOID: parseTypeOID(*row[0]), Subtype: *row[1], Opclass: *row[2], Collation: *row[3], Canonical: *row[4], SubtypeDiff: *row[5], RangeName: *row[6], MultirangeName: *row[7]}
		case "base":
			length, _ := strconv.Atoi(*row[8])
			metadata.Base = &TypeBase{Input: *row[0], Output: *row[1], Receive: *row[2], Send: *row[3], TypeModifierInput: *row[4], TypeModifierOutput: *row[5], Analyze: *row[6], Subscript: *row[7], Length: length, ByValue: *row[9] == "true", Alignment: *row[10], Storage: *row[11], Category: *row[12], Delimiter: *row[13], Preferred: *row[14] == "true", ElementOID: parseTypeOID(*row[15]), ArrayOID: parseTypeOID(*row[16])}
		}
	}
	if (metadata.Kind == "range" || metadata.Kind == "multirange" || metadata.Kind == "base") && (len(response.Rows) != 1 || !metadata.MembersComplete) {
		failure := typeFailure(conn, command, "result", "Type properties are incomplete or inaccessible.")
		return &failure
	}
	return nil
}

const typeDependencyNotice = "Direct pg_depend catalog references, including automatic arrays and extension membership. Shared-cluster dependencies and dynamic SQL references are not included."

const typeDependenciesSQL = `WITH targets AS (
SELECT 'pg_catalog.pg_type'::regclass::oid AS classid,$1::oid AS objid
UNION ALL SELECT 'pg_catalog.pg_class'::regclass::oid,$2::oid WHERE $2::oid<>0
), links AS (
SELECT 'incoming'::text AS direction,d.*,d.classid AS otherclass,d.objid AS otherid,d.objsubid AS othersubid
FROM pg_catalog.pg_depend d WHERE EXISTS(SELECT 1 FROM targets t WHERE t.classid=d.refclassid AND t.objid=d.refobjid)
UNION ALL
SELECT 'outgoing'::text AS direction,d.*,d.refclassid AS otherclass,d.refobjid AS otherid,d.refobjsubid AS othersubid
FROM pg_catalog.pg_depend d WHERE EXISTS(SELECT 1 FROM targets t WHERE t.classid=d.classid AND t.objid=d.objid)
)
SELECT l.direction,i.type::text AS "objectKind",i.schema::text AS "objectSchema",i.name::text AS "objectName",i.identity::text AS "objectIdentity",
l.deptype::text AS "dependencyClass",l.classid::text AS "classID",l.objid::text AS "objectID",l.objsubid::text AS "objectSubID",
l.refclassid::text AS "referencedClassID",l.refobjid::text AS "referencedObjectID",l.refobjsubid::text AS "referencedObjectSubID"
FROM links l CROSS JOIN LATERAL pg_catalog.pg_identify_object(l.otherclass,l.otherid,l.othersubid) i
ORDER BY l.direction,l.classid,l.objid,l.objsubid,l.refclassid,l.refobjid,l.refobjsubid,l.deptype`

func typeCatalog(ctx context.Context, conn *pgx.Conn, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	request := *command.Catalog
	switch request.Kind {
	case "typeDetails", "enumValues", "typeDependencies", "typeDDL", "name", "definition":
	default:
		return typeFailure(conn, command, "unsupported", "PostgreSQL type properties are available in the type inspector.")
	}
	metadata, failure := typeHeader(ctx, conn, command)
	if failure != nil {
		return *failure
	}
	if request.Kind == "enumValues" || request.Kind == "typeDependencies" {
		var sql, notice string
		params := typeParams(request.Identity)
		if request.Kind == "enumValues" {
			if metadata.Kind != "enum" {
				return typeFailure(conn, command, "unsupported", "Only enum types have ordered enum labels.")
			}
			sql = enumValuesSQL
		} else {
			sql, notice = typeDependenciesSQL, typeDependencyNotice
			params = append(params, []byte(strconv.FormatUint(uint64(metadata.RelationOID), 10)))
		}
		response := executeParamsSink(ctx, conn, command, sql, params, sink)
		if response.Type == "error" {
			if response.Category == "sql" {
				response.Message, response.ErrorPosition = "Type metadata is unavailable or access was denied. Refresh the catalog.", 0
			}
			return response
		}
		if request.Kind == "typeDependencies" {
			for _, row := range response.Rows {
				if len(row) != 12 {
					return typeFailure(conn, command, "result", "Dependency metadata is incomplete or inaccessible.")
				}
				for index, value := range row {
					if index != 2 && index != 3 && (value == nil || *value == "") {
						return typeFailure(conn, command, "result", "Dependency metadata is incomplete or inaccessible.")
					}
				}
			}
		}
		if _, failure = typeHeader(ctx, conn, command); failure != nil {
			return *failure
		}
		if notice != "" {
			response.DisplayNotice = strings.TrimSpace(response.DisplayNotice + " " + notice)
		}
		return response
	}
	if request.Kind == "name" {
		return typeStringResult(ctx, conn, command, sink, []string{"name"}, []*string{typeCell(pgx.Identifier{metadata.Schema, metadata.Name}.Sanitize())})
	}
	if failure = typeMembers(ctx, conn, command, &metadata); failure != nil {
		return *failure
	}
	if _, failure = typeHeader(ctx, conn, command); failure != nil {
		return *failure
	}
	if request.Kind == "typeDDL" {
		return typeDDL(ctx, conn, command, metadata, sink)
	}
	definition, status, limitations, details := typeDefinition(metadata)
	if request.Kind == "definition" {
		return typeStringResult(ctx, conn, command, sink, []string{"name", "definition", "definitionStatus", "limitations"}, []*string{typeCell(metadata.Name), definition, typeCell(status), typeCell(limitations)})
	}
	rename, enumChanges, operationLimitations := typeOperations(metadata)
	permissionHint := "Ownership and current server privileges are checked again by PostgreSQL at execution. The connection's execution policy applies to Run."
	if !metadata.OwnerAvailable {
		permissionHint = "The current role does not own or inherit ownership of this type. Preview is available; execution may require another role. " + permissionHint
	}
	kind := "type"
	if metadata.Kind == "enum" {
		kind = "enum"
	}
	return typeStringResult(ctx, conn, command, sink,
		[]string{"name", "kind", "schema", "identity", "typeKind", "owner", "definition", "definitionStatus", "details", "renameSupported", "addEnumValueSupported", "renameEnumValueSupported", "operationLimitations", "permissionHint"},
		[]*string{typeCell(metadata.Name), typeCell(kind), typeCell(metadata.Schema), typeCell(request.Identity), typeCell(metadata.Kind), typeCell(metadata.Owner), definition, typeCell(status), typeCell(details), typeCell(strconv.FormatBool(rename)), typeCell(strconv.FormatBool(enumChanges)), typeCell(strconv.FormatBool(enumChanges)), typeCell(operationLimitations), typeCell(permissionHint)})
}

func typeCell(value string) *string { return &value }

// Generated DDL travels only as a bound text value in this fixed SELECT. The
// catalog never submits it as SQL, including on the grant-exempt catalog path.
func typeStringResult(ctx context.Context, conn *pgx.Conn, command protocol.Command, sink adapter.ResultSink, columns []string, row []*string) protocol.Response {
	var projections []string
	params := make([][]byte, len(row))
	for index, name := range columns {
		projections = append(projections, fmt.Sprintf("$%d::text AS %s", index+1, pgx.Identifier{name}.Sanitize()))
		if row[index] != nil {
			params[index] = []byte(*row[index])
		}
	}
	// Avoid publishing a prefix of a definition or preview. The envelope/JSON
	// escaping budget is checked before streaming any of this single row.
	fields := make([]protocol.Column, len(columns))
	for index, name := range columns {
		fields[index] = protocol.Column{Index: index, Name: name, Engine: "postgresql", NativeType: "text", TypeOID: 25}
	}
	probe := protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, Columns: fields, Rows: [][]*string{row}}
	if !typeResultFits(probe) {
		return typeFailure(conn, command, "result", "Type information exceeds the supported display bound; no complete definition or preview is available.")
	}
	return executeParamsSink(ctx, conn, command, "SELECT "+strings.Join(projections, ","), params, sink)
}
