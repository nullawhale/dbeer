package session_test

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

type pgTypeFixture struct {
	h      *pgHarness
	schema string
	ctx    context.Context
}

func newPGTypeFixture(t *testing.T) *pgTypeFixture {
	t.Helper()
	h := newPGHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	f := &pgTypeFixture{h: h, schema: fmt.Sprintf("dbeer_types_%x_猫", time.Now().UnixNano()), ctx: ctx}
	f.exec("CREATE SCHEMA " + pgx.Identifier{f.schema}.Sanitize())
	t.Cleanup(func() {
		h.manager.Close()
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		_, _ = h.observer.Exec(cleanupCtx, "ROLLBACK")
		_, _ = h.observer.Exec(cleanupCtx, "DROP SCHEMA IF EXISTS "+pgx.Identifier{f.schema}.Sanitize()+" CASCADE")
		cancel()
	})
	return f
}

func (f *pgTypeFixture) qualified(name string) string {
	return pgx.Identifier{f.schema, name}.Sanitize()
}

func (f *pgTypeFixture) exec(sql string) {
	f.h.t.Helper()
	if _, err := f.h.observer.Exec(f.ctx, sql); err != nil {
		f.h.t.Fatal("cannot prepare disposable PostgreSQL type fixture")
	}
}

func (f *pgTypeFixture) reference(session, name, kind string) protocol.CatalogRequest {
	f.h.t.Helper()
	listed := f.h.catalog(session, protocol.CatalogRequest{Kind: "objects", Schema: f.schema, ObjectKind: kind})
	row := catalogFind(f.h.t, listed, name)
	return protocol.CatalogRequest{Schema: f.schema, Object: name, ObjectKind: kind, Identity: catalogText(f.h.t, listed, row, "identity")}
}

func typeRequest(reference protocol.CatalogRequest, kind string) protocol.CatalogRequest {
	reference.Kind = kind
	return reference
}

func previewTypeChange(t *testing.T, h *pgHarness, session string, reference protocol.CatalogRequest, change protocol.TypeChange) string {
	t.Helper()
	reference.Kind, reference.TypeChange = "typeDDL", &change
	response := h.catalog(session, reference)
	if response.Type != "query.result" || response.Truncated || len(response.Columns) != 2 || len(response.Rows) != 1 || response.SQL != "" || catalogText(t, response, 0, "warnings") == "" {
		t.Fatalf("type preview did not return bounded SQL text: type=%q category=%q state=%q", response.Type, response.Category, response.SQLState)
	}
	return catalogText(t, response, 0, "sql")
}

func TestPostgresTypeCatalogUnusedDefinitionsAndDependencyAddresses(t *testing.T) {
	f := newPGTypeFixture(t)
	h := f.h
	enumName := `unused "enum\Ω`
	f.exec("CREATE TYPE " + f.qualified(enumName) + " AS ENUM (E'z',E'',E'quote''\\\\猫',E'a')")
	f.exec("ALTER TYPE " + f.qualified(enumName) + " ADD VALUE E'middle' BEFORE E'a'")
	f.exec("CREATE TYPE " + f.qualified("zero labels") + " AS ENUM ()")
	f.exec("CREATE TYPE " + f.qualified("orphan") + " AS ENUM (E'unused')")
	f.exec("CREATE DOMAIN " + f.qualified("amount domain") + " AS numeric(12,4) DEFAULT 1.2500 NOT NULL CONSTRAINT positive CHECK(VALUE>0)")
	f.exec("CREATE TYPE " + f.qualified("standalone composite") + " AS (" + pgx.Identifier{`state "column`}.Sanitize() + " " + f.qualified(enumName) + ", note text COLLATE pg_catalog.\"C\")")
	f.exec("CREATE TYPE " + f.qualified("number range") + " AS RANGE (SUBTYPE=numeric,MULTIRANGE_TYPE_NAME=" + f.qualified("number multirange") + ")")
	f.exec("CREATE TABLE " + f.qualified("using table") + " (id integer, state " + f.qualified(enumName) + ", other_state " + f.qualified(enumName) + ")")
	f.exec("CREATE TYPE " + f.qualified("shell type"))
	f.exec("CREATE TYPE " + f.qualified("native base"))
	f.exec("CREATE FUNCTION " + f.qualified("native_base_in") + "(cstring) RETURNS " + f.qualified("native base") + " LANGUAGE internal IMMUTABLE STRICT AS 'int4in'")
	f.exec("CREATE FUNCTION " + f.qualified("native_base_out") + "(" + f.qualified("native base") + ") RETURNS cstring LANGUAGE internal IMMUTABLE STRICT AS 'int4out'")
	f.exec("CREATE TYPE " + f.qualified("native base") + " (INPUT=" + f.qualified("native_base_in") + ",OUTPUT=" + f.qualified("native_base_out") + ",INTERNALLENGTH=4,PASSEDBYVALUE,ALIGNMENT=int4)")
	secondSchema := f.schema + "_2"
	f.exec("CREATE SCHEMA " + pgx.Identifier{secondSchema}.Sanitize())
	t.Cleanup(func() {
		_, _ = h.observer.Exec(f.ctx, "DROP SCHEMA IF EXISTS "+pgx.Identifier{secondSchema}.Sanitize()+" CASCADE")
	})
	f.exec("CREATE TYPE " + pgx.Identifier{secondSchema, enumName}.Sanitize() + " AS ENUM (E'other server-local object')")
	service := h.connect()
	orphan := f.reference(service, "orphan", "enum")
	if unused := h.catalog(service, typeRequest(orphan, "typeDetails")); unused.Type != "query.result" || catalogText(t, unused, 0, "definitionStatus") != "complete" || !strings.Contains(catalogText(t, unused, 0, "definition"), "unused") {
		t.Fatal("a nonempty enum with no using table could not be inspected")
	}
	reference := f.reference(service, enumName, "enum")
	details := h.catalog(service, typeRequest(reference, "typeDetails"))
	if details.Type != "query.result" || details.Truncated || len(details.Rows) != 1 || len(details.Columns) != 14 || catalogText(t, details, 0, "typeKind") != "enum" || catalogText(t, details, 0, "definitionStatus") != "complete" {
		t.Fatalf("unused enum metadata was unavailable: type=%q category=%q", details.Type, details.Category)
	}
	values := h.catalog(service, typeRequest(reference, "enumValues"))
	want := []string{"z", "", "quote'\\猫", "middle", "a"}
	if values.Truncated || len(values.Rows) != len(want) {
		t.Fatal("enum values lost catalog completeness")
	}
	for index, label := range want {
		if catalogText(t, values, index, "label") != label || catalogText(t, values, index, "position") != strconv.Itoa(index+1) {
			t.Fatal("enum values changed exact labels, empty strings or server ordering")
		}
	}
	for _, change := range []protocol.TypeChange{
		{Operation: "addEnumValue", Value: typeStringPointer("z")},
		{Operation: "renameEnumValue", OldValue: typeStringPointer("missing"), Value: typeStringPointer("new")},
		{Operation: "renameType", NewName: typeStringPointer("zero labels")},
	} {
		request := typeRequest(reference, "typeDDL")
		request.TypeChange = &change
		if duplicate := h.catalog(service, request); duplicate.Type != "error" || duplicate.Category != "validation" {
			t.Fatal("duplicate or unavailable type/label preview was accepted")
		}
	}
	if !strings.Contains(catalogText(t, values, 3, "sortOrder"), ".") {
		t.Fatal("enum ordering fixture did not retain a fractional server sort order")
	}
	zero := f.reference(service, "zero labels", "enum")
	empty := h.catalog(service, typeRequest(zero, "enumValues"))
	if empty.Type != "query.result" || empty.Truncated || len(empty.Columns) != 3 || len(empty.Rows) != 0 || empty.DisplayNotice != "" {
		t.Fatal("a valid zero-label enum was confused with unavailable metadata")
	}
	listed := h.catalog(service, protocol.CatalogRequest{Kind: "objects", Schema: f.schema, ObjectKind: "type"})
	for _, name := range []string{"amount domain", "standalone composite", "number range", "number multirange"} {
		catalogFind(t, listed, name)
	}
	for row := range listed.Rows {
		name := catalogText(t, listed, row, "name")
		if name == "using table" || name == "shell type" || strings.HasPrefix(name, "_") || catalogText(t, listed, row, "typeKind") == "enum" {
			t.Fatal("user-defined type group leaked arrays, row types, shells or enums")
		}
	}
	for _, test := range []struct{ name, kind, status, content string }{
		{"amount domain", "domain", "partial", "numeric(12,4)"},
		{"standalone composite", "composite", "partial", `state ""column`},
		{"number range", "range", "unavailable", "Subtype: numeric"},
		{"number multirange", "multirange", "unavailable", "Generated multirange:"},
		{"native base", "base", "unavailable", "Input function:"},
	} {
		ref := f.reference(service, test.name, "type")
		response := h.catalog(service, typeRequest(ref, "typeDetails"))
		if response.Type != "query.result" || catalogText(t, response, 0, "typeKind") != test.kind || catalogText(t, response, 0, "definitionStatus") != test.status || !strings.Contains(catalogText(t, response, 0, "details"), test.content) {
			t.Fatalf("type properties or reconstruction limits were unavailable for %s", test.kind)
		}
		if test.kind == "multirange" && catalogText(t, response, 0, "renameSupported") != "false" {
			t.Fatal("derived multirange advertised a generated rename")
		}
	}
	name := h.catalog(service, typeRequest(reference, "name"))
	if catalogText(t, name, 0, "name") != f.qualified(enumName) {
		t.Fatal("Copy Name lost PostgreSQL type identifier quoting")
	}
	found := h.catalog(service, protocol.CatalogRequest{Kind: "search", Search: enumName})
	identities := map[string]bool{}
	for row := range found.Rows {
		if catalogText(t, found, row, "name") == enumName && catalogText(t, found, row, "kind") == "enum" {
			identities[catalogText(t, found, row, "identity")] = true
		}
	}
	if len(identities) != 2 {
		t.Fatal("type search lost distinct schema-local OIDs")
	}
	dependencies := h.catalog(service, typeRequest(reference, "typeDependencies"))
	if dependencies.Type != "query.result" || dependencies.Truncated || len(dependencies.Columns) != 12 || !strings.Contains(dependencies.DisplayNotice, "dynamic SQL") {
		t.Fatal("type dependencies were unavailable or lost their catalog scope")
	}
	incomingColumn, outgoingNamespace, automaticArray := false, false, false
	for row := range dependencies.Rows {
		direction, kind := catalogText(t, dependencies, row, "direction"), catalogText(t, dependencies, row, "objectKind")
		for _, column := range []string{"classID", "objectID", "objectSubID", "referencedClassID", "referencedObjectID", "referencedObjectSubID"} {
			if _, err := strconv.ParseUint(catalogText(t, dependencies, row, column), 10, 32); err != nil {
				t.Fatal("dependency metadata lost a complete catalog address")
			}
		}
		if direction == "incoming" && kind == "table column" && catalogText(t, dependencies, row, "objectSubID") != "0" {
			incomingColumn = true
		}
		if direction == "outgoing" && kind == "schema" {
			outgoingNamespace = true
		}
		if direction == "incoming" && catalogText(t, dependencies, row, "dependencyClass") == "i" && kind == "type" {
			automaticArray = true
		}
	}
	if !incomingColumn || !outgoingNamespace || !automaticArray {
		t.Fatal("direct dependency metadata omitted columns, namespace or automatic arrays")
	}
	composite := f.reference(service, "standalone composite", "type")
	compositeDependencies := h.catalog(service, typeRequest(composite, "typeDependencies"))
	foundAttribute := false
	for row := range compositeDependencies.Rows {
		if catalogText(t, compositeDependencies, row, "direction") == "outgoing" && catalogText(t, compositeDependencies, row, "objectSubID") != "0" && catalogText(t, compositeDependencies, row, "referencedObjectID") == reference.Identity {
			foundAttribute = true
		}
	}
	if !foundAttribute {
		t.Fatal("standalone composite dependency addresses omitted attribute subobjects")
	}
}

func TestPostgresTypePreviewsAreReadonlyAndRunUsesExactPolicy(t *testing.T) {
	for _, stringMode := range []string{"on", "off"} {
		t.Run(stringMode, func(t *testing.T) {
			f := newPGTypeFixture(t)
			h := f.h
			name, renamed, oldLabel, newLabel := `status "\猫`, `renamed "\Ω`, `old'\猫`, `new'\Ω`
			f.exec("CREATE TYPE " + f.qualified(name) + " AS ENUM (E'old''\\\\猫')")
			writer := h.connect()
			h.query(writer, "SET standard_conforming_strings="+stringMode, "idle")
			reference := f.reference(writer, name, "enum")
			policy := protocol.ExecutionPolicy{Environment: "production", ReadOnly: true}
			h.connection.Policy = &policy
			reader := h.connect()
			h.connection.Policy = nil
			changes := []protocol.TypeChange{
				{Operation: "renameType", NewName: &renamed},
				{Operation: "addEnumValue", Value: typeStringPointer("")},
				{Operation: "renameEnumValue", OldValue: &oldLabel, Value: &newLabel},
			}
			var previews []string
			for _, change := range changes {
				sql := previewTypeChange(t, h, reader, reference, change)
				previews = append(previews, sql)
				h.send(protocol.Command{Type: "operation.assess", RequestID: h.id(), SessionID: reader, QueryID: h.id(), Operations: []protocol.OperationRequest{{Type: "execute", SQL: sql}}})
				assessment := h.receive()
				if assessment.Type != "operation.assessment" || assessment.Assessment == nil || assessment.Assessment.Decision != "deny" || assessment.Assessment.Authorization != "" {
					t.Fatal("readonly enum SQL assessment was not denied")
				}
				h.send(protocol.Command{Type: "execute", RequestID: h.id(), SessionID: reader, QueryID: h.id(), SQL: sql, Authorization: "tampered-grant"})
				if response := h.receive(); response.Type != "error" || response.Category != "policy" || !response.SQLNotExecuted {
					t.Fatal("readonly enum DDL reached the database")
				}
				before := h.catalog(writer, typeRequest(reference, "enumValues"))
				if len(before.Rows) != 1 || catalogText(t, before, 0, "label") != oldLabel {
					t.Fatal("catalog preview mutated the enum")
				}
			}
			// Every generated ALTER requires an ordinary exact-SQL grant.
			for _, sql := range previews {
				h.send(protocol.Command{Type: "execute", RequestID: h.id(), SessionID: writer, QueryID: h.id(), SQL: sql})
				if response := h.receive(); response.Category != "policy" || !response.SQLNotExecuted {
					t.Fatal("generated ALTER bypassed normal confirmation")
				}
			}
			command := h.authorized(protocol.Command{Type: "execute", RequestID: h.id(), SessionID: writer, QueryID: h.id(), SQL: previews[1]})
			command.SQL += " -- changed after assessment"
			h.send(command)
			if response := h.receive(); response.Category != "policy" || !response.SQLNotExecuted {
				t.Fatal("tampered enum SQL reused an exact operation grant")
			}
			for _, index := range []int{1, 2, 0} {
				h.query(writer, previews[index], "idle")
			}
			newReference := f.reference(writer, renamed, "enum")
			if newReference.Identity != reference.Identity {
				t.Fatal("renaming a type unexpectedly changed its local OID")
			}
			after := h.catalog(writer, typeRequest(newReference, "enumValues"))
			if len(after.Rows) != 2 || catalogText(t, after, 0, "label") != newLabel || catalogText(t, after, 1, "label") != "" {
				t.Fatal("generated label DDL lost quotes, backslashes, Unicode, empty labels or order")
			}
			if stale := h.catalog(writer, typeRequest(reference, "typeDetails")); stale.Type != "error" {
				t.Fatal("old type name was silently rebound after rename")
			}
		})
	}
}

func typeStringPointer(value string) *string { return &value }

func typeTestLiteral(value string) string {
	return "E'" + strings.ReplaceAll(strings.ReplaceAll(value, `\`, `\\`), "'", "''") + "'"
}

func TestPostgresTypeCatalogPrivilegesStaleHandlesAndExtensionRestrictions(t *testing.T) {
	f := newPGTypeFixture(t)
	h := f.h
	f.exec("CREATE TYPE " + f.qualified("restricted") + " AS ENUM (E'old')")
	f.exec("CREATE TABLE " + f.qualified("unreadable table") + " (state " + f.qualified("restricted") + ")")
	f.exec("CREATE DOMAIN " + f.qualified("rename domain") + " AS text")
	f.exec("CREATE TYPE " + f.qualified("extension managed") + " AS ENUM (E'managed')")
	f.exec("ALTER EXTENSION plpgsql ADD TYPE " + f.qualified("extension managed"))
	t.Cleanup(func() {
		_, _ = h.observer.Exec(f.ctx, "ALTER EXTENSION plpgsql DROP TYPE "+f.qualified("extension managed"))
	})
	writer := h.connect()
	domain := f.reference(writer, "rename domain", "type")
	domainSQL := previewTypeChange(t, h, writer, domain, protocol.TypeChange{Operation: "renameType", NewName: typeStringPointer("renamed domain")})
	if !strings.HasPrefix(domainSQL, "ALTER DOMAIN ") {
		t.Fatal("domain preview used ALTER TYPE")
	}
	h.query(writer, domainSQL, "idle")
	reference := f.reference(writer, "restricted", "enum")
	extension := f.reference(writer, "extension managed", "enum")
	managed := h.catalog(writer, typeRequest(extension, "typeDetails"))
	if catalogText(t, managed, 0, "renameSupported") != "false" || catalogText(t, managed, 0, "addEnumValueSupported") != "false" || !strings.Contains(catalogText(t, managed, 0, "operationLimitations"), "extension") {
		t.Fatal("extension ownership did not restrict generated changes")
	}
	extension.Kind, extension.TypeChange = "typeDDL", &protocol.TypeChange{Operation: "addEnumValue", Value: typeStringPointer("new")}
	if blocked := h.catalog(writer, extension); blocked.Type != "error" || blocked.Category != "unsupported" {
		t.Fatal("extension-managed type accepted a generated preview")
	}
	extensionDependencies := h.catalog(writer, typeRequest(f.reference(writer, "extension managed", "enum"), "typeDependencies"))
	extensionMember := false
	for row := range extensionDependencies.Rows {
		if catalogText(t, extensionDependencies, row, "direction") == "outgoing" && catalogText(t, extensionDependencies, row, "dependencyClass") == "e" && catalogText(t, extensionDependencies, row, "objectKind") == "extension" {
			extensionMember = true
		}
	}
	if !extensionMember {
		t.Fatal("extension membership was absent from full-address dependency inspection")
	}
	role := fmt.Sprintf("dbeer_type_reader_%x", time.Now().UnixNano())
	f.exec("CREATE ROLE " + pgx.Identifier{role}.Sanitize())
	t.Cleanup(func() {
		h.manager.Close()
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = h.observer.Exec(cleanupCtx, "DROP OWNED BY "+pgx.Identifier{role}.Sanitize())
		_, _ = h.observer.Exec(cleanupCtx, "DROP ROLE IF EXISTS "+pgx.Identifier{role}.Sanitize())
	})
	f.exec("REVOKE ALL ON TYPE " + f.qualified("restricted") + " FROM PUBLIC")
	reader := h.connect()
	h.query(reader, "SET ROLE "+pgx.Identifier{role}.Sanitize(), "idle")
	if denied := h.catalog(reader, typeRequest(reference, "typeDetails")); denied.Type != "error" || strings.Contains(denied.Message, f.schema) {
		t.Fatal("denied type metadata was reported as complete or disclosed identifiers")
	}
	f.exec("GRANT USAGE ON SCHEMA " + pgx.Identifier{f.schema}.Sanitize() + " TO " + pgx.Identifier{role}.Sanitize())
	if denied := h.catalog(reader, typeRequest(reference, "enumValues")); denied.Type != "error" {
		t.Fatal("schema privilege bypassed type USAGE")
	}
	f.exec("GRANT USAGE ON TYPE " + f.qualified("restricted") + " TO " + pgx.Identifier{role}.Sanitize())
	visible := h.catalog(reader, typeRequest(reference, "typeDetails"))
	if visible.Type != "query.result" || catalogText(t, visible, 0, "renameSupported") != "true" || !strings.Contains(catalogText(t, visible, 0, "permissionHint"), "does not own") {
		t.Fatal("metadata access required ownership or lost its permission hint")
	}
	previewTypeChange(t, h, reader, reference, protocol.TypeChange{Operation: "addEnumValue", Value: typeStringPointer("new")})
	unreadable := h.query(reader, "SELECT pg_catalog.has_table_privilege("+typeTestLiteral(f.qualified("unreadable table"))+",'SELECT')::text", "idle")
	if len(unreadable.Rows) != 1 || unreadable.Rows[0][0] == nil || *unreadable.Rows[0][0] != "false" {
		t.Fatal("privilege fixture did not prove metadata independence from table SELECT")
	}
	h.query(reader, "RESET ROLE", "idle")
	// Drop/recreate keeps the qualified name while changing the validated OID.
	f.exec("DROP TABLE " + f.qualified("unreadable table"))
	f.exec("DROP TYPE " + f.qualified("restricted"))
	f.exec("CREATE TYPE " + f.qualified("restricted") + " AS ENUM (E'recreated')")
	for _, kind := range []string{"typeDetails", "enumValues", "typeDependencies", "typeDDL", "definition", "name"} {
		request := typeRequest(reference, kind)
		if kind == "typeDDL" {
			request.TypeChange = &protocol.TypeChange{Operation: "addEnumValue", Value: typeStringPointer("new")}
		}
		if stale := h.catalog(writer, request); stale.Type != "error" || !stale.Connected || stale.OutcomeUnknown {
			t.Fatal("stale local type identity silently rebound to the recreated type")
		}
	}
	fresh := f.reference(writer, "restricted", "enum")
	if fresh.Identity == reference.Identity {
		t.Fatal("drop/recreate fixture did not change its local OID")
	}
	for _, mutate := range []func(*protocol.CatalogRequest){
		func(r *protocol.CatalogRequest) { r.Schema = "public" },
		func(r *protocol.CatalogRequest) { r.Object = "wrong name" },
		func(r *protocol.CatalogRequest) { r.ObjectKind = "type" },
	} {
		request := typeRequest(fresh, "typeDetails")
		mutate(&request)
		if response := h.catalog(writer, request); response.Type != "error" {
			t.Fatal("type identity was accepted under a different namespace, name or kind")
		}
	}
}

func TestPostgresTypeCatalogBoundsAndCompleteZeroDependencies(t *testing.T) {
	f := newPGTypeFixture(t)
	h := f.h
	labels := make([]string, 1002)
	for index := range labels {
		labels[index] = fmt.Sprintf("E'label_%04d'", index)
	}
	f.exec("CREATE TYPE " + f.qualified("bounded") + " AS ENUM (" + strings.Join(labels, ",") + ")")
	f.exec("CREATE TYPE " + f.qualified("zero dependencies") + " AS ENUM ()")
	service := h.connect()
	reference := f.reference(service, "bounded", "enum")
	values := h.catalog(service, typeRequest(reference, "enumValues"))
	if values.Type != "query.result" || !values.Truncated || len(values.Rows) != 1000 || values.RowCount != 1002 {
		t.Fatal("bounded enum output lost its incomplete-set disclosure")
	}
	details := h.catalog(service, typeRequest(reference, "typeDetails"))
	if details.Type != "query.result" || catalogText(t, details, 0, "definitionStatus") != "partial" || catalogCell(t, details, 0, "definition") != nil || catalogText(t, details, 0, "addEnumValueSupported") != "false" {
		t.Fatal("bounded metadata prefix became a complete definition or writable label set")
	}
	reference.Kind, reference.TypeChange = "typeDDL", &protocol.TypeChange{Operation: "addEnumValue", Value: typeStringPointer("unseen")}
	if preview := h.catalog(service, reference); preview.Type != "error" || preview.Category != "unsupported" {
		t.Fatal("incomplete enum labels were used for duplicate-sensitive generation")
	}
	columns := make([]string, 1002)
	for index := range columns {
		columns[index] = fmt.Sprintf("c%d %s", index, f.qualified("bounded"))
	}
	f.exec("CREATE TABLE " + f.qualified("many references") + " (" + strings.Join(columns, ",") + ")")
	dependencies := h.catalog(service, typeRequest(f.reference(service, "bounded", "enum"), "typeDependencies"))
	if dependencies.Type != "query.result" || !dependencies.Truncated || len(dependencies.Rows) != 1000 || dependencies.DisplayNotice == "" {
		t.Fatal("dependency bounds became a complete or empty reference assertion")
	}
	zero := f.reference(service, "zero dependencies", "enum")
	// PostgreSQL normally records a namespace and array dependency for every
	// enum. Remove only this fixture's links in an explicit test transaction,
	// then roll back, to exercise a genuine successful zero-row catalog result.
	h.query(service, "BEGIN", "transaction")
	h.query(service, "DELETE FROM pg_catalog.pg_depend WHERE (classid='pg_catalog.pg_type'::regclass AND objid="+zero.Identity+") OR (refclassid='pg_catalog.pg_type'::regclass AND refobjid="+zero.Identity+")", "transaction")
	empty := h.catalog(service, typeRequest(zero, "typeDependencies"))
	if empty.Type != "query.result" || empty.Truncated || len(empty.Rows) != 0 || len(empty.Columns) != 12 || !strings.Contains(empty.DisplayNotice, "Direct pg_depend") || strings.Contains(empty.DisplayNotice, "No catalog information") {
		t.Fatal("complete empty dependencies were confused with missing or denied type metadata")
	}
	h.query(service, "ROLLBACK", "idle")
}

func TestPostgresTypeBlockedDDLCanCancelAndReuseItsSession(t *testing.T) {
	f := newPGTypeFixture(t)
	h := f.h
	f.exec("CREATE TYPE " + f.qualified("locked") + " AS ENUM (E'old')")
	service := h.connect()
	reference := f.reference(service, "locked", "enum")
	sql := previewTypeChange(t, h, service, reference, protocol.TypeChange{Operation: "addEnumValue", Value: typeStringPointer("cancelled")})
	f.exec("BEGIN")
	f.exec("ALTER TYPE " + f.qualified("locked") + " RENAME VALUE E'old' TO E'pending'")
	pid := h.pid(service)
	command := h.start(service, sql)
	waitCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		var waiting bool
		if h.observer.QueryRow(waitCtx, "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND wait_event_type='Lock')", pid).Scan(&waiting) != nil {
			t.Fatal("cannot observe disposable type-lock wait")
		}
		if waiting {
			break
		}
		select {
		case <-waitCtx.Done():
			t.Fatal("generated enum operation did not wait for its type lock")
		case <-time.After(10 * time.Millisecond):
		}
	}
	stop := protocol.Command{Type: "cancel", RequestID: h.id(), SessionID: service, QueryID: command.QueryID}
	h.send(stop)
	for range 2 {
		response := h.receive()
		if response.RequestID == stop.RequestID {
			if response.Type != "cancel.ack" || response.Status != "accepted" {
				t.Fatal("enum Stop was not acknowledged")
			}
		} else if response.RequestID != command.RequestID || response.Type != "error" || response.Category != "cancelled" || !response.Connected || response.OutcomeUnknown {
			t.Fatal("cancelled enum lock wait lost its known outcome or connection")
		}
	}
	f.exec("ROLLBACK")
	h.query(service, "SELECT 42", "idle")
	values := h.catalog(service, typeRequest(reference, "enumValues"))
	if len(values.Rows) != 1 || catalogText(t, values, 0, "label") != "old" {
		t.Fatal("cancelled generated DDL mutated the enum or prevented session reuse")
	}
}
