package tableedit

import (
	"encoding/json"
	"strings"
)

func ValidBaseline(b Baseline) bool {
	if !b.Target.Valid() || b.Target.Reconcile || !IsDigest(b.Fingerprint) || b.Engine != "postgresql" && b.Engine != "mysql" || len(b.Columns) > MaxColumns || len(b.Keys) > 256 || len(b.Indexes) > 256 || len(b.Limitations) > 64 {
		return false
	}
	raw, e := json.Marshal(b)
	if e != nil || len(raw) > 4<<20 {
		return false
	}
	private, e := json.Marshal([]any{b.Facts, b.Attributes})
	if e != nil || len(private) > 4<<20 {
		return false
	}
	for _, c := range b.Columns {
		if !Identifier(c.Name) || len(c.NativeType) > 4096 || strings.ContainsRune(c.NativeType, 0) || c.DefaultExpression != nil && len(*c.DefaultExpression) > 65536 {
			return false
		}
	}
	for _, s := range b.Limitations {
		if len(s) > 4096 {
			return false
		}
	}
	for _, x := range b.Indexes {
		if !Identifier(x.Name) || len(x.Columns) > 32 {
			return false
		}
		for _, c := range x.Columns {
			if !Identifier(c) {
				return false
			}
		}
	}
	for _, k := range b.Keys {
		if !Identifier(k.Name) || len(k.Columns) > 32 || len(k.ReferenceColumns) > 32 {
			return false
		}
		for _, c := range append(append([]string(nil), k.Columns...), k.ReferenceColumns...) {
			if !Identifier(c) {
				return false
			}
		}
	}
	return true
}
