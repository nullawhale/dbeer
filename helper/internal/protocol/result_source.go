package protocol

import (
	"encoding/json"
	"errors"
)

// ResultSource is ephemeral provenance from a completed, explicitly supported
// SELECT. It is never restored, inferred from labels, or trusted as permission
// to write: changes.preview/apply independently reload and validate the table.
type ResultSource struct {
	Schema           string               `json:"schema"`
	Table            string               `json:"table"`
	Columns          []ResultSourceColumn `json:"columns"`
	ReadOnlyReason   string               `json:"readOnlyReason,omitempty"`
	OperationSupport *OperationSupport    `json:"operationSupport,omitempty"`
}

// Each entry aligns with one result column. TableIndex is the canonical table
// ordinal used to reconstruct the complete original row for existing Apply.
type ResultSourceColumn struct {
	Name       string `json:"name"`
	NativeType string `json:"nativeType"`
	TableIndex int    `json:"tableIndex"`
	PrimaryKey int    `json:"primaryKey"`
	Editable   bool   `json:"editable"`
	Generated  bool   `json:"generated"`
}

// An unsupported source carries an empty array, preserving a stable wire shape.
func (source ResultSource) MarshalJSON() ([]byte, error) {
	if source.OperationSupport != nil && (!source.OperationSupport.Valid() || source.OperationSupport.Scope != "result") {
		return nil, errors.New("invalid source operation support")
	}
	type plain ResultSource
	if source.Columns == nil {
		source.Columns = []ResultSourceColumn{}
	}
	return json.Marshal(plain(source))
}
