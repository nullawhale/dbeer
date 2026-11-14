package mysql

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash"
	"time"

	"dbeer/helper/internal/protocol"
)

// Each collection is rechecked by ReadCatalogMetadata. The whole observation
// remains best effort across collections, with strict row/byte/time budgets.
func (s *Session) ObserveSchema(ctx context.Context, c protocol.Command) protocol.Response {
	if c.SchemaObservation.Action != "poll" {
		r := protocol.ErrorResponse(c, "capability", "MySQL schema observation uses metadata fingerprints and needs no installation.")
		r.Connected, r.TransactionStatus = !s.closed.Load(), s.TransactionStatus()
		return r
	}
	observation := protocol.SchemaObservation{Engine: "mysql", Action: "poll", Tables: c.SchemaObservation.Tables, Mode: "fingerprint", ObservedAt: time.Now().UTC().Format(time.RFC3339Nano), Complete: true, Notices: []string{"The fingerprint covers selected tables' columns, keys and indexes. Collections are separate best-effort observations."}}
	sink := &schemaObservationDigest{hash: sha256.New()}
	for _, table := range c.SchemaObservation.Tables {
		for _, kind := range []string{"columns", "foreignKeys", "indexes"} {
			selector := protocol.CatalogRequest{Kind: kind, Schema: table.Schema, Object: table.Name, ObjectKind: "table"}
			marker, _ := json.Marshal(selector)
			sink.hash.Write(marker)
			request := c
			request.Type = "catalog"
			request.Catalog = &selector
			r, _ := s.ReadCatalogMetadata(ctx, request, sink)
			if r.Type == "error" {
				r.Message = "MySQL schema observation failed. Enable it explicitly after checking connection and metadata permissions."
				r.ErrorPosition = 0
				r.OutcomeUnknown = false
				return r
			}
			if r.MetadataStale || r.DisplayNotice != "" || sink.limited {
				observation.Complete = false
				observation.Notices = append(observation.Notices, "Metadata was limited, changed during collection, or carried a server warning. Build explicitly and inspect the affected table.")
				break
			}
		}
		if !observation.Complete {
			break
		}
	}
	if observation.Complete {
		observation.Revision = hex.EncodeToString(sink.hash.Sum(nil))
	}
	observation.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return protocol.Response{Type: "monitor.schema.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SchemaObservation: &observation, Connected: !s.closed.Load(), TransactionStatus: s.TransactionStatus()}
}

type schemaObservationDigest struct {
	hash        hash.Hash
	rows, bytes int
	limited     bool
}

func (s *schemaObservationDigest) Begin(index int, columns []protocol.Column) error {
	data, _ := json.Marshal(columns)
	return s.write(data)
}
func (s *schemaObservationDigest) Row(index int, row []*string) error {
	s.rows++
	data, _ := json.Marshal(row)
	return s.write(data)
}
func (s *schemaObservationDigest) End(index int, summary protocol.ResultSet) error { return nil }
func (s *schemaObservationDigest) write(data []byte) error {
	s.bytes += len(data)
	if s.rows > 25000 || s.bytes > 16*1024*1024 {
		s.limited = true
		return errors.New("schema observation metadata limit")
	}
	_, err := s.hash.Write(data)
	return err
}
