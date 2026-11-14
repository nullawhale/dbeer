package mariadb

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"hash"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func (s *Session) ReadCatalogMetadata(ctx context.Context, c protocol.Command, sink adapter.ResultSink) (protocol.Response, string) {
	failure := func(category, message string) (protocol.Response, string) {
		r := protocol.ErrorResponse(c, category, message)
		r.Connected, r.TransactionStatus = !s.closed.Load(), s.TransactionStatus()
		return r, "bestEffort"
	}
	if c.Catalog == nil || !c.Catalog.Valid() {
		return failure("validation", "Invalid native catalog metadata request.")
	}
	if s.TransactionStatus() != "idle" {
		return failure("busy", "Metadata capture requires an idle service session.")
	}
	request := *c.Catalog
	switch request.Kind {
	case "schemas", "objects", "search", "columns", "foreignKeys", "referencingTables", "keys", "indexes", "constraints", "triggers":
	default:
		return failure("validation", "This native catalog request is not a structured metadata collection.")
	}
	first := &mariaDBMetadataDigest{destination: sink, hash: sha256.New(), normalizeIdentity: request.Kind == "objects" || request.Kind == "search"}
	warning := false
	read := func(destination adapter.ResultSink) protocol.Response {
		var target *protocol.CatalogRelationTarget
		response := s.executeWith(ctx, c, func(collector *collector, result *wire.Result) error {
			if err := s.requireNativeMetadataEncoding(); err != nil {
				return &adapter.ConnectionError{Category: "validation", Message: "Native catalog metadata requires existing utf8mb4 client, connection and result encodings."}
			}
			if request.Kind == "referencingTables" {
				observed, err := s.work.client.Execute(`SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED') LIMIT 2`, request.Schema, request.Object)
				if err != nil {
					return err
				}
				if observed.RowNumber() != 1 {
					observed.Close()
					return &adapter.ConnectionError{Category: "validation", Message: "The exact native relation target is unavailable."}
				}
				schema, e1 := observed.GetString(0, 0)
				name, e2 := observed.GetString(0, 1)
				target = &protocol.CatalogRelationTarget{Schema: strings.Clone(schema), Name: strings.Clone(name)}
				observed.Close()
				if e1 != nil || e2 != nil || target.Schema != request.Schema || target.Name != request.Object {
					return &adapter.ConnectionError{Category: "validation", Message: "The native relation target changed."}
				}
			}
			query, args, err := catalogQuery(request)
			if err != nil {
				return &adapter.ConnectionError{Category: "validation", Message: err.Error()}
			}
			query = strings.TrimSuffix(query, " LIMIT 1001")
			statement, err := s.work.client.Prepare(query)
			if err != nil {
				return err
			}
			defer func() {
				if statement.Close() != nil {
					collector.statementCleanupFailed = true
				}
			}()
			err = statement.ExecuteSelectStreaming(result, collector.row, collector.columns, args...)
			warning = warning || result.Warnings != 0
			return err
		}, destination)
		response.MetadataTarget = target
		return response
	}
	response := read(first)
	if response.Truncated && response.DisplayNotice == "Result display is limited to 1000 rows and 8 MiB. The command completed in full." {
		response.DisplayNotice = ""
	}
	if response.Type == "error" {
		response.Message = "MariaDB catalog metadata is unavailable or access was denied."
		return response, "bestEffort"
	}
	second := &mariaDBMetadataDigest{hash: sha256.New(), normalizeIdentity: first.normalizeIdentity}
	verified := read(second)
	if verified.Type == "error" {
		verified.Message = "MariaDB catalog verification is unavailable or access was denied."
		return verified, "bestEffort"
	}
	if string(first.hash.Sum(nil)) != string(second.hash.Sum(nil)) || response.MetadataTarget != nil && (verified.MetadataTarget == nil || *response.MetadataTarget != *verified.MetadataTarget) {
		response.MetadataStale = true
		response.DisplayNotice = "The MariaDB catalog changed during metadata capture. Refresh explicitly."
	} else if warning {
		response.DisplayNotice = "The server reported a metadata warning; the observation may be incomplete."
	}
	return response, "bestEffort"
}

type mariaDBMetadataDigest struct {
	destination       adapter.ResultSink
	hash              hash.Hash
	normalizeIdentity bool
}

func (s *mariaDBMetadataDigest) Begin(index int, columns []protocol.Column) error {
	raw, _ := json.Marshal(columns)
	s.hash.Write(raw)
	if s.destination != nil {
		return s.destination.Begin(index, columns)
	}
	return nil
}
func (s *mariaDBMetadataDigest) Row(index int, row []*string) error {
	if s.normalizeIdentity && len(row) > 3 && row[0] != nil {
		row = append([]*string{}, row...)
		identity := catalogIdentity(*row[0])
		row[3] = &identity
	}
	raw, _ := json.Marshal(row)
	s.hash.Write(raw)
	if s.destination != nil {
		return s.destination.Row(index, row)
	}
	return nil
}
func (s *mariaDBMetadataDigest) End(index int, summary protocol.ResultSet) error {
	if s.destination != nil {
		return s.destination.End(index, summary)
	}
	return nil
}
