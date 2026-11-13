// Package sqlcomplete implements offline SQL completion. It has no database,
// UI, or LSP dependencies. All source ranges are UTF-8 byte offsets; protocol
// adapters are responsible for translating their editor's position encoding.
package sqlcomplete

type ForeignKeyColumn struct {
	Source string `json:"source"`
	Target string `json:"target"`
}

type ColumnTypeEntry struct {
	Name       string `json:"name"`
	NativeType string `json:"nativeType"`
}

type ForeignKey struct {
	Origin       string             `json:"origin,omitempty"`
	Name         string             `json:"name"`
	TargetSchema string             `json:"targetSchema"`
	TargetTable  string             `json:"targetTable"`
	Columns      []ForeignKeyColumn `json:"columns"`
}

type Relation struct {
	PartitionKeys     []string            `json:"partitionKeys,omitempty"`
	ClusteringColumns []string            `json:"clusteringColumns,omitempty"`
	StaticColumns     []string            `json:"staticColumns,omitempty"`
	Schema            string              `json:"schema"`
	Name              string              `json:"name"`
	Kind              string              `json:"kind"`
	Columns           []string            `json:"columns"`
	ColumnTypes       map[string]string   `json:"columnTypes,omitempty"`
	ColumnTypeEntries []ColumnTypeEntry   `json:"columnTypeEntries,omitempty"`
	ForeignKeys       []ForeignKey        `json:"foreignKeys,omitempty"`
	Signatures        []FunctionSignature `json:"signatures,omitempty"`
}

type FunctionParameter struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Position int    `json:"position,omitempty"`
	Optional bool   `json:"optional,omitempty"`
	Variadic bool   `json:"variadic,omitempty"`
}

type FunctionSignature struct {
	Parameters []FunctionParameter `json:"parameters"`
	ReturnType string              `json:"returnType"`
}

// Signature labels use byte ranges like the rest of this package. LSP converts
// parameter spans to UTF-16 offsets within Label, not within the SQL document.
type Signature struct {
	Label           string
	Parameters      []ParameterSpan
	ActiveParameter int
}
type ParameterSpan struct{ Start, End int }
type SignatureHelp struct {
	Signatures      []Signature
	ActiveSignature int
	CallStart       int
}

type Context struct {
	Keyspace string
	Engine   string
	Catalog  []Relation
}

type Item struct {
	Label, InsertText, Detail string
	Kind                      int
	Start, End                int
	// Matches are ordered, non-overlapping UTF-8 byte spans within Label.
	Matches   []MatchSpan
	priority  int
	match     matchRank
	sortLabel string
}

type MatchSpan struct{ Start, End int }

type Diagnostic struct {
	Start, End int
	Message    string
}

// Native entries keep exact identifier bytes end to end. An entry list, even
// when incomplete, never falls back to the legacy map for a missing name.
func (r Relation) nativeType(name string) string {
	if r.ColumnTypeEntries != nil {
		value := ""
		for _, entry := range r.ColumnTypeEntries {
			if entry.Name == name {
				if value != "" {
					return ""
				}
				value = entry.NativeType
			}
		}
		return value
	}
	return r.ColumnTypes[name]
}
