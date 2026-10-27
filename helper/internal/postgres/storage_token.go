package postgres

import (
	"context"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
)

const postgresStorageAlias = "__dbeer_storage_token"
const postgresStorageProjection = `('pgrow-v1/' || tableoid::text || '/' || ctid::text || '/' || xmin::text)`

var postgresStoragePattern = regexp.MustCompile(`^pgrow-v1/[0-9]{1,10}/\([0-9]{1,10},[0-9]{1,5}\)/[0-9]{1,10}$`)

func validPostgresStorageToken(value string) bool {
	return len(value) <= 80 && postgresStoragePattern.MatchString(value)
}

// Legacy clients have no MVCC token. Their fallback remains available only for
// server types with known round-trip output, recursively through containers.
func postgresLosslessType(ctx context.Context, conn *pgx.Conn, oid uint32, cache map[uint32]bool, loading map[uint32]bool) (bool, error) {
	if known, ok := cache[oid]; ok {
		return known, nil
	}
	if loading[oid] {
		return true, nil
	}
	loading[oid] = true
	defer delete(loading, oid)
	var kind, typeName string
	var base, element, relation uint32
	var array bool
	err := conn.QueryRow(ctx, `SELECT t.typtype::pg_catalog.text,t.typname::pg_catalog.text,t.typbasetype,t.typelem,t.typrelid,EXISTS(SELECT 1 FROM pg_catalog.pg_type e WHERE e.oid=t.typelem AND e.typarray=t.oid) FROM pg_catalog.pg_type t WHERE t.oid=$1::pg_catalog.oid`, oid).Scan(&kind, &typeName, &base, &element, &relation, &array)
	if err != nil {
		return false, err
	}
	supported := false
	switch {
	case array:
		supported, err = postgresLosslessType(ctx, conn, element, cache, loading)
	case kind == "e":
		supported = true
	case kind == "d":
		supported, err = postgresLosslessType(ctx, conn, base, cache, loading)
	case kind == "r" || kind == "m":
		var subtype uint32
		if err = conn.QueryRow(ctx, "SELECT rngsubtype FROM pg_catalog.pg_range WHERE rngtypid=$1::pg_catalog.oid OR rngmultitypid=$1::pg_catalog.oid", oid).Scan(&subtype); err == nil {
			supported, err = postgresLosslessType(ctx, conn, subtype, cache, loading)
		}
	case kind == "c":
		rows, e := conn.Query(ctx, "SELECT atttypid FROM pg_catalog.pg_attribute WHERE attrelid=$1::pg_catalog.oid AND attnum>0 AND NOT attisdropped ORDER BY attnum", relation)
		if e != nil {
			return false, e
		}
		ids := []uint32{}
		for rows.Next() {
			var id uint32
			if e = rows.Scan(&id); e != nil {
				rows.Close()
				return false, e
			}
			ids = append(ids, id)
		}
		rows.Close()
		if rows.Err() != nil {
			return false, rows.Err()
		}
		supported = true
		for _, id := range ids {
			var okay bool
			okay, err = postgresLosslessType(ctx, conn, id, cache, loading)
			if err != nil || !okay {
				supported = false
				break
			}
		}
	case kind == "b":
		switch oid {
		case 16, 17, 18, 19, 20, 21, 23, 25, 26, 114, 142, 650, 700, 701, 774, 790, 829, 869, 1042, 1043, 1082, 1083, 1114, 1184, 1186, 1266, 1560, 1562, 1700, 2950, 3802:
			supported = !postgresOutputSensitiveBuiltin(typeName)
		}
	}
	if err == nil {
		cache[oid] = supported
	}
	return supported, err
}

func compareStorageLockedRow(ctx context.Context, conn *pgx.Conn, table changeTable, token string) error {
	if !validPostgresStorageToken(token) {
		return changeInvalid("The row storage identity is invalid. Reload the table.")
	}
	parts := strings.Split(token, "/")
	reader := conn.PgConn().ExecParams(ctx, "SELECT "+postgresStorageProjection+" FROM "+table.name+" WHERE tableoid=$1::pg_catalog.oid AND ctid=$2::tid AND xmin=$3::xid FOR UPDATE", [][]byte{[]byte(parts[1]), []byte(parts[2]), []byte(parts[3])}, nil, nil, nil)
	rows, matched := 0, true
	for reader.NextRow() {
		rows++
		values := reader.Values()
		matched = matched && len(values) == 1 && values[0] != nil && string(values[0]) == token
	}
	_, e := reader.Close()
	if e != nil {
		return e
	}
	if rows != 1 || !matched {
		return changeConflict("A row was changed or deleted by another client. No changes were committed. Reload and compare the data.")
	}
	return nil
}
