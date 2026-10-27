package postgres

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

// Parse/Describe obtains result types before Execute. Metadata reads use the
// owning connection, including its uncommitted types and temporary schema.
// The named statement survives those reads and is executed exactly once.
func prepareQueryTypes(ctx context.Context, conn *pgx.Conn, sql string) (string, []protocol.Column, []pgconn.FieldDescription, error) {
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", nil, nil, err
	}
	name := "dbeer_types_" + hex.EncodeToString(token[:])
	description, err := conn.PgConn().Prepare(ctx, name, sql, nil)
	if err != nil {
		releaseQueryTypes(conn, name)
		return "", nil, nil, err
	}
	columns := newResultCollector(protocol.Command{}, description.Fields, MaxResultBytes).response.Columns
	limits := sc.DefaultLimits()
	collector := sc.NewCollector(ctx, limits)
	r := &schemaCapture{skipCustomTypeFormatting: true, ctx: ctx, tx: conn, sink: collector, spec: sc.CaptureSpec{Limits: limits}, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}}
	for index, field := range description.Fields {
		column := &columns[index]
		if native, known := conn.TypeMap().TypeForOID(field.DataTypeOID); known && field.DataTypeOID < 16384 {
			column.NativeType = native.Name
			if field.DataTypeOID == 17 {
				column.Encoding = "base64"
			}
			// Preserve familiar display names while retaining exact typmods in
			// snapshots. OIDs remain local provenance only.
			digest := sha256.Sum256([]byte(native.Name + ":" + strconv.FormatInt(int64(field.TypeModifier), 10)))
			column.TypeIdentity = "pgtype-v1:" + hex.EncodeToString(digest[:])
			if !postgresQueryBuiltinOutputStable(native, map[uint32]bool{}) {
				column.TypeIdentity = "unresolved:" + column.TypeIdentity
			}
			if native.Name == "record" || native.Name == "unknown" {
				column.NativeType = "oid:" + strconv.FormatUint(uint64(field.DataTypeOID), 10)
			}
			continue
		}
		if r.version == 0 {
			if err = conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4", pgx.QueryExecModeExec).Scan(&r.version); err != nil {
				releaseQueryTypes(conn, name)
				return "", nil, nil, err
			}
		}
		use, lookupErr := r.typeUse(strconv.FormatUint(uint64(field.DataTypeOID), 10), int64(field.TypeModifier), 0)
		if lookupErr != nil {
			releaseQueryTypes(conn, name)
			return "", nil, nil, lookupErr
		}
		identity, identityErr := tc.PostgresType(use, collector.Capture.Types)
		if identityErr != nil {
			// Incomplete observations retain the explicit unresolved identity;
			// they must not establish equality merely by sharing a name.
			continue
		}
		column.NativeType = pgx.Identifier{use.Ref.Schema, use.Ref.Name}.Sanitize()
		if use.Kind == "array" {
			column.NativeType += "[]"
		}
		digest := sha256.Sum256([]byte(identity))
		column.TypeIdentity = "pgtype-v1:" + hex.EncodeToString(digest[:])
		if !postgresQueryLosslessUse(use, collector.Capture.Types, map[sc.Ref]bool{}) {
			column.TypeIdentity = "unresolved:" + column.TypeIdentity
		}
		if postgresDataBase(use, collector.Capture.Types) == "bytea" {
			column.Encoding = "base64"
		}
	}
	return name, columns, description.Fields, nil
}

func releaseQueryTypes(conn *pgx.Conn, name string) {
	if name == "" || conn.IsClosed() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Protocol Close works even in an aborted transaction and never replays SQL.
	if conn.PgConn().Deallocate(ctx, name) != nil {
		closeConnection(conn)
	}
}

func assignQueryTypes(columns []protocol.Column, fields []pgconn.FieldDescription) bool {
	if len(columns) != len(fields) {
		return false
	}
	for index, field := range fields {
		if columns[index].TypeOID != field.DataTypeOID || !strings.EqualFold(columns[index].Engine, "postgresql") {
			return false
		}
	}
	return true
}

func postgresQueryBuiltinOutputStable(typ *pgtype.Type, visited map[uint32]bool) bool {
	if typ == nil || postgresOutputSensitiveBuiltin(typ.Name) {
		return false
	}
	if visited[typ.OID] {
		return true
	}
	visited[typ.OID] = true
	switch codec := typ.Codec.(type) {
	case *pgtype.ArrayCodec:
		return postgresQueryBuiltinOutputStable(codec.ElementType, visited)
	case *pgtype.RangeCodec:
		return postgresQueryBuiltinOutputStable(codec.ElementType, visited)
	case *pgtype.MultirangeCodec:
		return postgresQueryBuiltinOutputStable(codec.ElementType, visited)
	case *pgtype.CompositeCodec:
		for _, field := range codec.Fields {
			if !postgresQueryBuiltinOutputStable(field.Type, visited) {
				return false
			}
		}
	}
	return true
}
