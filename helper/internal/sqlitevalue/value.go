package sqlitevalue

import (
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
)

// Value retains the storage class of each cell, independently of affinity.
// Text and blob payloads are base64 bytes; real payloads are binary64 hex bits.
type Value struct {
	Type  string `json:"type"`
	Value string `json:"value,omitempty"`
}

func (v Value) Valid() bool {
	switch v.Type {
	case "null":
		return v.Value == ""
	case "integer":
		n, e := strconv.ParseInt(v.Value, 10, 64)
		return e == nil && strconv.FormatInt(n, 10) == v.Value
	case "real":
		b, e := hex.DecodeString(v.Value)
		return e == nil && len(b) == 8 && v.Value == strings.ToLower(v.Value)
	case "text", "blob":
		b, e := base64.StdEncoding.DecodeString(v.Value)
		return e == nil && len(b) <= 8*1024*1024 && base64.StdEncoding.EncodeToString(b) == v.Value
	default:
		return false
	}
}
