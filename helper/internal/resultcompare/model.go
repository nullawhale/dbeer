// Package resultcompare compares immutable typed row sources without database,
// protocol, or SQL dependencies. Exact saved strings are never normalized.
package resultcompare

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

type Column struct {
	Index                                            int
	Name, Engine, NativeType, TypeIdentity, Encoding string
}
type Metadata struct {
	Columns  []Column
	RowCount int64
	Complete bool
}
type RowRef struct {
	Index, Offset int64
	Length        int
	Digest        [32]byte
}

// Source metadata and cell strings must remain immutable for the source lifetime.
// Scan and ReadRow must stop when their context is cancelled.
type Source interface {
	Metadata() Metadata
	Scan(context.Context, func(RowRef, []*string) error) error
	ReadRow(context.Context, RowRef) ([]*string, error)
	Close() error
}
type Mapping struct {
	Left  int  `json:"left"`
	Right int  `json:"right"`
	Key   bool `json:"key,omitempty"`
}
type Options struct {
	Mode        string
	Columns     []Mapping
	ScratchDir  string
	QuotaBytes  int64
	MemoryBytes int
	FanIn       int
}
type SchemaDifference struct {
	Left   *int   `json:"left,omitempty"`
	Right  *int   `json:"right,omitempty"`
	Reason string `json:"reason"`
}
type Summary struct {
	LeftRows                   int64              `json:"leftRows"`
	RightRows                  int64              `json:"rightRows"`
	EqualRows                  int64              `json:"equalRows"`
	AddedRows                  int64              `json:"addedRows"`
	DeletedRows                int64              `json:"deletedRows"`
	ChangedRows                int64              `json:"changedRows"`
	AmbiguousRows              int64              `json:"ambiguousRows"`
	UncertainRows              int64              `json:"uncertainRows"`
	ReportRows                 int64              `json:"reportRows"`
	Complete                   bool               `json:"complete"`
	FullEquality               bool               `json:"fullEquality"`
	SchemaDifferences          []SchemaDifference `json:"schemaDifferences"`
	SchemaDifferenceCount      int64              `json:"schemaDifferenceCount"`
	SchemaDifferencesTruncated bool               `json:"schemaDifferencesTruncated"`
	Warnings                   []string           `json:"warnings"`
}
type Preview struct {
	IsNull     bool   `json:"isNull"`
	Preview    string `json:"preview"`
	TotalBytes int64  `json:"totalBytes"`
	Truncated  bool   `json:"truncated"`
	ValueRef   string `json:"valueRef"`
}
type Cell struct {
	Mapping   int      `json:"mapping"`
	Left      *Preview `json:"left,omitempty"`
	Right     *Preview `json:"right,omitempty"`
	Different bool     `json:"different"`
	Uncertain bool     `json:"uncertain"`
}
type Row struct {
	Index          int64  `json:"index"`
	Kind           string `json:"kind"`
	LeftIndex      *int64 `json:"leftIndex,omitempty"`
	RightIndex     *int64 `json:"rightIndex,omitempty"`
	Cells          []Cell `json:"cells"`
	CellsTruncated bool   `json:"cellsTruncated"`
	CellOffset     int    `json:"cellOffset"`
	NextCellOffset int    `json:"nextCellOffset"`
	TotalCells     int    `json:"totalCells"`
}
type Page struct {
	Offset     int64 `json:"offset"`
	NextOffset int64 `json:"nextOffset"`
	HasMore    bool  `json:"hasMore"`
	Rows       []Row `json:"rows"`
}
type Value struct {
	ValueRef   string `json:"valueRef"`
	IsNull     bool   `json:"isNull"`
	TotalBytes int64  `json:"totalBytes"`
	Offset     int64  `json:"offset"`
	NextOffset int64  `json:"nextOffset"`
	DataBase64 string `json:"dataBase64"`
	HasMore    bool   `json:"hasMore"`
}

var ErrConfiguration = errors.New("Invalid comparison configuration.")
var ErrQuota = errors.New("Comparison scratch quota exceeded.")
var ErrSource = errors.New("Comparison source changed or is unavailable.")
var ErrReference = errors.New("Comparison reference is invalid.")
var ErrClosed = errors.New("Comparison is closed.")

func known(c Column) bool {
	if strings.TrimSpace(c.Engine) == "" || strings.TrimSpace(c.NativeType) == "" ||
		strings.HasPrefix(strings.ToLower(strings.TrimSpace(c.NativeType)), "oid:") ||
		strings.HasPrefix(strings.ToLower(strings.TrimSpace(c.TypeIdentity)), "unresolved:") {
		return false
	}
	return c.TypeIdentity != "" || legacyScalar(c)
}
func sameType(a, b Column) bool {
	return a.Engine == b.Engine && a.NativeType == b.NativeType && effectiveIdentity(a) == effectiveIdentity(b) && a.Encoding == b.Encoding
}

// Legacy snapshots have no structural fingerprint. Only parameterless built-in
// scalar names can identify a type completely without that missing evidence.
func legacyScalar(c Column) bool {
	var names string
	switch c.Engine {
	case "postgresql":
		// Output GUCs can make dates ambiguous and round floats (including
		// geometry); old snapshots contain no rendering evidence for them.
		names = "|bool|bytea|char|name|int2|int4|int8|oid|text|json|xml|uuid|jsonb|inet|cidr|macaddr|macaddr8|pg_lsn|tsvector|tsquery|"
	case "cassandra":
		names = "|ascii|text|varchar|blob|boolean|tinyint|smallint|int|bigint|counter|varint|decimal|float|double|uuid|timeuuid|inet|date|time|timestamp|duration|"
	default:
		return false
	}
	return strings.Contains(names, "|"+c.NativeType+"|")
}

func effectiveIdentity(c Column) string {
	if c.Engine == "cassandra" && legacyScalar(c) {
		return "cassandra-scalar-v1:" + c.NativeType
	}
	if c.TypeIdentity == "" && c.Engine == "postgresql" && legacyScalar(c) {
		digest := sha256.Sum256([]byte(c.NativeType + ":-1"))
		return "pgtype-v1:" + hex.EncodeToString(digest[:])
	}
	return c.TypeIdentity
}
func sameValue(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
func intp(n int) *int             { return &n }
func validate(left, right Metadata, o Options) (Summary, error) {
	s := Summary{LeftRows: left.RowCount, RightRows: right.RowCount, Complete: left.Complete && right.Complete, SchemaDifferences: []SchemaDifference{}, Warnings: []string{}}
	if left.RowCount < 0 || right.RowCount < 0 {
		return s, ErrConfiguration
	}
	if len(o.Columns) == 0 || o.Mode != "key" && o.Mode != "rowOrder" {
		return s, ErrConfiguration
	}
	usedL, usedR := map[int]bool{}, map[int]bool{}
	keys := 0
	for _, m := range o.Columns {
		if m.Left < 0 || m.Left >= len(left.Columns) || m.Right < 0 || m.Right >= len(right.Columns) || usedL[m.Left] || usedR[m.Right] {
			return s, ErrConfiguration
		}
		usedL[m.Left], usedR[m.Right] = true, true
		if m.Key {
			keys++
		}
		a, b := left.Columns[m.Left], right.Columns[m.Right]
		if a.Name != b.Name {
			s.addSchema(SchemaDifference{intp(m.Left), intp(m.Right), "Column names differ."})
		}
		if !sameType(a, b) {
			s.addSchema(SchemaDifference{intp(m.Left), intp(m.Right), "Column engine, native type, or encoding differs."})
		}
		if !known(a) || !known(b) {
			s.addSchema(SchemaDifference{intp(m.Left), intp(m.Right), "Stable type identity is unavailable."})
		}
	}
	if o.Mode == "key" && keys == 0 || o.Mode == "rowOrder" && keys != 0 {
		return s, ErrConfiguration
	}
	for i := range left.Columns {
		if !usedL[i] {
			s.addSchema(SchemaDifference{Left: intp(i), Reason: "Left column is excluded."})
		}
	}
	for i := range right.Columns {
		if !usedR[i] {
			s.addSchema(SchemaDifference{Right: intp(i), Reason: "Right column is excluded."})
		}
	}
	if !left.Complete {
		s.Warnings = append(s.Warnings, "Left input is partial; complete-set equality cannot be established.")
	}
	if !right.Complete {
		s.Warnings = append(s.Warnings, "Right input is partial; complete-set equality cannot be established.")
	}
	return s, nil
}

// addSchema retains a bounded set of static examples; exact counts still gate equality.
func (s *Summary) addSchema(d SchemaDifference) {
	s.SchemaDifferenceCount++
	if len(s.SchemaDifferences) < 64 {
		s.SchemaDifferences = append(s.SchemaDifferences, d)
	} else {
		s.SchemaDifferencesTruncated = true
	}
}
