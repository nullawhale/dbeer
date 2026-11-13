package mysql

import (
	"context"
	"crypto/sha256"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"hash"
	"strings"
)

func (s *Session) ReadCatalogMetadata(ctx context.Context, c protocol.Command, sink adapter.ResultSink) (protocol.Response, string) {
	if s.TransactionStatus() != "idle" {
		r := protocol.ErrorResponse(c, "busy", "Metadata capture requires an idle service session.")
		r.Connected, r.TransactionStatus = true, s.TransactionStatus()
		return r, "bestEffort"
	}
	r := *c.Catalog
	first := &metadataDigest{destination: sink, hash: sha256.New(), normalizeIdentity: r.Kind == "objects" || r.Kind == "search"}
	metadataWarning := false
	read := func(destination adapter.ResultSink) protocol.Response {
		var target *protocol.CatalogRelationTarget
		response := s.executeWith(ctx, c, func(collector *collector, result *wire.Result) error {
			selector := r
			if r.Kind == "columns" {
				if err := s.requireNativeMetadataEncoding(); err != nil {
					return err
				}
			}
			if r.Object != "" {
				var err error
				selector.Schema, selector.Object, err = s.nativeBrowseTarget(r.Schema, r.Object)
				if err != nil {
					return err
				}
				if r.Kind == "referencingTables" {
					target = &protocol.CatalogRelationTarget{Schema: selector.Schema, Name: selector.Object}
				}
			}
			query, args := catalogQuery(selector)
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
			metadataWarning = metadataWarning || result.Warnings > 0
			return err
		}, destination)
		response.MetadataTarget = target
		return response
	}
	response := read(first)
	// The metadata sink receives every row before the ordinary display limit.
	if response.Truncated && response.DisplayNotice == "Result display is limited to 1000 rows and 8 MiB. The command completed in full." {
		response.DisplayNotice = ""
	}
	if response.Type == "error" {
		response.Message = "Metadata is unavailable or access was denied."
		return response, "bestEffort"
	}
	second := &metadataDigest{hash: sha256.New(), normalizeIdentity: first.normalizeIdentity}
	verified := read(second)
	if verified.Type == "error" {
		return verified, "bestEffort"
	}
	if string(first.hash.Sum(nil)) != string(second.hash.Sum(nil)) ||
		(response.MetadataTarget != nil && (verified.MetadataTarget == nil || *response.MetadataTarget != *verified.MetadataTarget)) {
		response.MetadataStale = true
		response.DisplayNotice = "The MySQL catalog changed during metadata capture. Refresh explicitly."
	}
	if metadataWarning && !response.MetadataStale {
		response.DisplayNotice = "The server reported a metadata warning. Inspect the full object definition for complete details."
	}
	return response, "bestEffort"
}

type metadataDigest struct {
	destination       adapter.ResultSink
	hash              hash.Hash
	normalizeIdentity bool
}

func (s *metadataDigest) Begin(index int, columns []protocol.Column) error {
	data, _ := json.Marshal(columns)
	s.hash.Write(data)
	if s.destination != nil {
		return s.destination.Begin(index, columns)
	}
	return nil
}
func (s *metadataDigest) Row(index int, row []*string) error {
	if s.normalizeIdentity && len(row) > 3 && row[0] != nil {
		row = append([]*string{}, row...)
		identity := catalogIdentity(*row[0])
		row[3] = &identity
	}
	data, _ := json.Marshal(row)
	s.hash.Write(data)
	if s.destination != nil {
		return s.destination.Row(index, row)
	}
	return nil
}
func (s *metadataDigest) End(index int, summary protocol.ResultSet) error {
	if s.destination != nil {
		return s.destination.End(index, summary)
	}
	return nil
}
