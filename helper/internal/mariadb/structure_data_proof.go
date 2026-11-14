package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

const mariaDBStructureRowLimit = 100000
const mariaDBStructureRowBytes = 32 << 20

type mariaDBStructureRows struct {
	names           []string
	rows            map[string]int
	counter, lastID *string
}

// Apply-only exact duplicate-preserving evidence. Hexadecimal native scalars
// retain NULL separately; additional native storage projections retain floating
// and timestamp representations that ordinary display text cannot identify.
func (s *Session) captureMariaDBStructureRows(b tableedit.Baseline, excluded ...string) (proof *mariaDBStructureRows, err error) {
	if b.Facts == nil || !b.Facts.Table.Columns.Complete || b.Advanced != nil {
		return nil, tableedit.ErrUnsupported
	}
	proof = &mariaDBStructureRows{rows: map[string]int{}}
	kinds := map[string]string{}
	skip := map[string]bool{}
	for _, name := range excluded {
		if _, ok := tableedit.FindColumn(b, name); !ok || skip[name] {
			return nil, tableedit.ErrUnsupported
		}
		skip[name] = true
	}
	for _, c := range b.Facts.Table.Columns.Items {
		if skip[c.Ref.Name] {
			continue
		}
		if c.Type.Value == nil || !MariaDBEditableKind(c.Type.Value.Ref.Name) {
			return nil, tableedit.ErrUnsupported
		}
		proof.names = append(proof.names, c.Ref.Name)
		kinds[c.Ref.Name] = c.Type.Value.Ref.Name
	}
	sort.Strings(proof.names)
	projection := []string{}
	for _, name := range proof.names {
		projection = append(projection, "HEX(CAST("+MariaDBStableProjection(name, kinds[name])+" AS BINARY))")
	}
	if len(projection) == 0 {
		projection = append(projection, "1")
	}
	storage := MariaDBStorageColumns(kinds)
	projection = append(projection, MariaDBStorageProjections(storage, kinds)...)
	r, e := s.work.client.Execute("SELECT CAST(AUTO_INCREMENT AS CHAR),CAST(LAST_INSERT_ID() AS CHAR) FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 2", b.Target.Schema, b.Target.Table)
	if e != nil {
		return nil, e
	}
	if r.RowNumber() != 1 || r.ColumnNumber() != 2 {
		r.Close()
		return nil, tableedit.ErrUnsupported
	}
	for i, dst := range []**string{&proof.counter, &proof.lastID} {
		null, e := r.IsNull(0, i)
		if e != nil {
			r.Close()
			return nil, e
		}
		if !null {
			v, e := r.GetString(0, i)
			if e != nil {
				r.Close()
				return nil, e
			}
			owned := strings.Clone(v)
			*dst = &owned
		}
	}
	r.Close()
	drained := false
	defer func() {
		if !drained {
			s.Close()
		}
	}()
	sql := "SELECT " + strings.Join(projection, ",") + " FROM " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " LIMIT 100001"
	if e = s.sendTextQuery(sql); e != nil {
		return nil, e
	}
	packet, e := s.flowPacket(1 << 20)
	if e != nil {
		return nil, e
	}
	if len(packet) > 0 && packet[0] == wire.ERR_HEADER {
		drained = true
		return nil, s.work.client.HandleErrorPacket(packet)
	}
	count, n, ok := lengthEncoded(packet)
	if !ok || n != len(packet) || int(count) != len(projection) {
		return nil, wire.ErrMalformPacket
	}
	for i := 0; i < int(count); i++ {
		p, e := s.flowPacket(1 << 20)
		if e != nil {
			return nil, e
		}
		if _, e = wire.FieldData(p).Parse(); e != nil {
			return nil, e
		}
	}
	eof, e := s.flowPacket(1 << 20)
	if e != nil || len(eof) != 5 || eof[0] != wire.EOF_HEADER {
		return nil, wire.ErrMalformPacket
	}
	size, rows := 0, 0
	for {
		p, e := s.flowPacket(16 << 20)
		if e != nil {
			return nil, e
		}
		if len(p) == 5 && p[0] == wire.EOF_HEADER {
			drained = true
			break
		}
		if len(p) > 0 && p[0] == wire.ERR_HEADER {
			drained = true
			return nil, s.work.client.HandleErrorPacket(p)
		}
		fields, e := nativeTextFields(p, int(count))
		if e != nil {
			return nil, e
		}
		values := make([]*string, len(fields))
		for i, f := range fields {
			if f != nil {
				v := string(f)
				values[i] = &v
			}
		}
		encoded, e := json.Marshal(values)
		if e != nil {
			return nil, e
		}
		size += len(encoded)
		rows++
		if rows > mariaDBStructureRowLimit || size > mariaDBStructureRowBytes {
			return nil, errors.New("The native preservation proof exceeds its bounded row/byte limit; no further DDL is sent.")
		}
		proof.rows[string(encoded)]++
	}
	return proof, nil
}
func (a *mariaDBStructureRows) preserved(b *mariaDBStructureRows) bool {
	return a != nil && b != nil && reflect.DeepEqual(a.names, b.names) && reflect.DeepEqual(a.rows, b.rows) && reflect.DeepEqual(a.counter, b.counter) && reflect.DeepEqual(a.lastID, b.lastID)
}

func mariaDBStructureDataPreserved(b tableedit.Baseline, before, after *mariaDBStructureRows, conditions []tableedit.Condition) bool {
	if before == nil || after == nil {
		return false
	}
	if len(conditions) == 1 && conditions[0].Operation.Change != nil && conditions[0].Operation.Change.Identity != nil {
		change := conditions[0].Operation.Change
		old, ok := tableedit.FindColumn(b, change.Name)
		if !ok || old.Identity.Value == nil {
			return false
		}
		if old.Identity.Value.Kind != change.Identity.Kind {
			if change.Identity.Kind == "none" {
				if before.counter == nil || after.counter != nil {
					return false
				}
			} else if change.Identity.Kind == "autoIncrement" {
				if before.counter != nil || after.counter == nil {
					return false
				}
				n, e := strconv.ParseUint(*after.counter, 10, 64)
				if e != nil || n == 0 || strconv.FormatUint(n, 10) != *after.counter {
					return false
				}
			} else {
				return false
			}
			comparison := *after
			comparison.counter = before.counter
			return before.preserved(&comparison)
		}
	}
	return before.preserved(after)
}
