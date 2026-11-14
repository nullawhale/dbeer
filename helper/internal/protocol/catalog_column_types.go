package protocol

// CatalogColumnTypesCapability makes the ordered entries authoritative; the
// legacy JSON object cannot preserve canonically equivalent identifier keys.
const CatalogColumnTypesCapability = "catalogColumnTypesV1"

type CatalogColumnComparison struct {
	Kind              string `json:"kind"`
	BaseType          string `json:"baseType"`
	Charset           string `json:"charset,omitempty"`
	CollationSchema   string `json:"collationSchema,omitempty"`
	CollationName     string `json:"collationName,omitempty"`
	CollationIdentity string `json:"collationIdentity,omitempty"`
}

type CatalogColumnTypeEntry struct {
	Name       string                   `json:"name"`
	NativeType string                   `json:"nativeType"`
	Comparison *CatalogColumnComparison `json:"comparison,omitempty"`
}
