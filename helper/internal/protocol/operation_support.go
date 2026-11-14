package protocol

import (
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"
)

const OperationSupportCapability = "operationSupportV1"

// OperationSupport describes eligibility in the context of its owning reply.
// Object and result evidence is ephemeral and never grants write permission.
type OperationSupport struct {
	Version    int                     `json:"version"`
	Engine     string                  `json:"engine"`
	Scope      string                  `json:"scope"`
	Operations []OperationAvailability `json:"operations"`
}

type OperationAvailability struct {
	Operation string `json:"operation"`
	State     string `json:"state"`
	Reason    string `json:"reason,omitempty"`
}

func (s OperationSupport) Valid() bool {
	if s.Version != 1 || len(s.Operations) == 0 || len(s.Operations) > 64 {
		return false
	}
	switch s.Engine {
	case "postgresql", "mysql", "mariadb", "sqlite", "cassandra", "mongodb":
	default:
		return false
	}
	if s.Scope != "session" && s.Scope != "structure" && s.Scope != "result" {
		return false
	}
	seen := make(map[string]bool, len(s.Operations))
	for _, operation := range s.Operations {
		if !operation.Valid() || seen[operation.Operation] {
			return false
		}
		seen[operation.Operation] = true
	}
	return true
}

func (s OperationAvailability) Valid() bool {
	if len(s.Operation) == 0 || len(s.Operation) > 128 {
		return false
	}
	for i, c := range s.Operation {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && (c >= '0' && c <= '9' || c == '.')) {
			return false
		}
	}
	if s.State == "available" {
		return s.Reason == ""
	}
	return (s.State == "unavailable" || s.State == "requiresMetadata") &&
		len(s.Reason) > 0 && len(s.Reason) <= 1024 && utf8.ValidString(s.Reason) && !strings.ContainsRune(s.Reason, 0)
}

func (s *OperationSupport) UnmarshalJSON(raw []byte) error {
	if _, ok := changesObject(raw, "version|engine|scope|operations", "version", "engine", "scope", "operations"); !ok {
		return errors.New("invalid operation support")
	}
	type plain OperationSupport
	var value plain
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	if !OperationSupport(value).Valid() {
		return errors.New("invalid operation support")
	}
	*s = OperationSupport(value)
	return nil
}

func (s *OperationAvailability) UnmarshalJSON(raw []byte) error {
	fields, ok := changesObject(raw, "operation|state|reason", "operation", "state")
	if !ok {
		return errors.New("invalid operation availability")
	}
	type plain OperationAvailability
	var value plain
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	if !OperationAvailability(value).Valid() {
		return errors.New("invalid operation availability")
	}
	if _, present := fields["reason"]; present && (value.State == "available" || !required(fields, "reason")) {
		return errors.New("invalid operation availability reason")
	}
	*s = OperationAvailability(value)
	return nil
}
