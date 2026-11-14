package mariadb

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	sc "dbeer/helper/internal/schemacompare"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type mariaFieldRead struct {
	ref    sc.Ref
	names  []string
	digest string
}

// COM_FIELD_LIST sends the stored default record, not evaluated DEFAULT SQL.
// Its database switch belongs solely to this short-lived metadata connection.
func (r *mariaSchemaCapture) nativeFields(ref sc.Ref) ([]*wire.Field, error) {
	if !sc.ValidName(ref.Schema) || !sc.ValidName(ref.Name) {
		return nil, fmt.Errorf("%w: native default names", sc.ErrInvalid)
	}
	owner, e := r.rows("SELECT CURRENT_USER(),CURRENT_ROLE(),DATABASE()")
	if e != nil || len(owner) != 1 || len(owner[0]) != 3 {
		return nil, fmt.Errorf("%w: native default owner metadata", sc.ErrInvalid)
	}
	var fields []*wire.Field
	if mariaText(owner[0], 2) == ref.Schema {
		fields, e = r.s.work.client.FieldList(ref.Name, "")
		if e != nil {
			r.wireError = e
			return nil, e
		}
	} else {
		control, cleanup, e := r.openMetadataControl(owner[0])
		if e != nil {
			return nil, e
		}
		defer cleanup()

		if e = control.client.UseDB(ref.Schema); e != nil {
			return nil, fmt.Errorf("%w: native default schema selection", sc.ErrInvalid)
		}
		fields, e = control.client.FieldList(ref.Name, "")
		if e != nil {
			return nil, fmt.Errorf("%w: native default field metadata", sc.ErrInvalid)
		}
	}
	if len(fields) > r.spec.Limits.Members {
		return nil, sc.ErrLimit
	}
	owned := make([]*wire.Field, len(fields))
	seen := map[string]bool{}
	size := 0
	for i, field := range fields {
		if field == nil || !bytes.Equal(field.Schema, []byte(ref.Schema)) || !bytes.Equal(field.OrgTable, []byte(ref.Name)) || len(field.Name) == 0 || seen[string(field.Name)] || len(field.DefaultValue) > r.spec.Limits.Scalar {
			return nil, fmt.Errorf("%w: native default field origin", sc.ErrInvalid)
		}
		seen[string(field.Name)] = true
		size += len(field.Data)
		if size > r.spec.Limits.Bytes {
			return nil, sc.ErrLimit
		}
		cloned := *field
		cloned.Data = bytes.Clone(field.Data)
		cloned.Schema = bytes.Clone(field.Schema)
		cloned.Table = bytes.Clone(field.Table)
		cloned.OrgTable = bytes.Clone(field.OrgTable)
		cloned.Name = bytes.Clone(field.Name)
		cloned.OrgName = bytes.Clone(field.OrgName)
		cloned.DefaultValue = bytes.Clone(field.DefaultValue)
		owned[i] = &cloned
	}
	r.bytes += size
	if r.bytes > r.spec.Limits.Bytes {
		return nil, sc.ErrLimit
	}
	return owned, nil
}

func mariaFieldDigest(fields []*wire.Field, names []string) string {
	byName := map[string]*wire.Field{}
	for _, field := range fields {
		byName[string(field.Name)] = field
	}
	selected := []*wire.Field{}
	for _, name := range names {
		field := byName[name]
		if field == nil {
			return ""
		}
		selected = append(selected, field)
	}
	raw, e := json.Marshal(selected)
	if e != nil {
		return ""
	}
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}
func (r *mariaSchemaCapture) trackNativeDefaults(ref sc.Ref, names []string) (map[string]*wire.Field, error) {
	fields, e := r.nativeFields(ref)
	if e != nil {
		return nil, e
	}
	digest := mariaFieldDigest(fields, names)
	if digest == "" {
		return nil, sc.ErrInvalid
	}
	r.fieldReads = append(r.fieldReads, mariaFieldRead{ref: ref, names: append([]string(nil), names...), digest: digest})
	selected := make(map[string]bool, len(names))
	for _, name := range names {
		selected[name] = true
	}
	byName := map[string]*wire.Field{}
	for _, field := range fields {
		if selected[string(field.Name)] {
			byName[string(field.Name)] = field
		}
	}
	return byName, nil
}
func (r *mariaSchemaCapture) nativeDefaultsFresh() error {
	for _, read := range r.fieldReads {
		fields, e := r.nativeFields(read.ref)
		if e != nil {
			return e
		}
		if mariaFieldDigest(fields, read.names) != read.digest {
			return sc.ErrInvalid
		}
	}
	return nil
}
