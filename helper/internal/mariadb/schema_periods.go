package mariadb

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type mariaPeriodRead struct {
	ref     sc.Ref
	columns []MariaDBPeriodColumn
	digest  string
}

func (r *mariaSchemaCapture) readPeriods(ref sc.Ref, columns []MariaDBPeriodColumn) ([]MariaDBPeriodColumn, error) {
	return MariaDBSystemPeriods(func(sql string, args ...any) (*wire.Result, error) {
		result, e := r.s.work.client.Execute(sql, args...)
		if e != nil {
			r.wireError = e
		}
		return result, e
	}, ref.Schema, ref.Name, "SYSTEM VERSIONED", columns)
}
func (r *mariaSchemaCapture) nativePeriods(ref sc.Ref, columns []MariaDBPeriodColumn) ([]MariaDBPeriodColumn, error) {
	periods, e := r.readPeriods(ref, columns)
	if e != nil {
		return nil, e
	}
	raw, e := json.Marshal(periods)
	if e != nil {
		return nil, sc.ErrInvalid
	}
	r.periodReads = append(r.periodReads, mariaPeriodRead{ref: ref, columns: columns, digest: string(raw)})
	return periods, nil
}
func (r *mariaSchemaCapture) nativePeriodsFresh() error {
	for _, read := range r.periodReads {
		periods, e := r.readPeriods(read.ref, read.columns)
		if e != nil {
			return e
		}
		raw, e := json.Marshal(periods)
		if e != nil || string(raw) != read.digest {
			return sc.ErrInvalid
		}
	}
	return nil
}
