package mariadb

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"errors"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

// DatabaseToolsServerVersion uses the native observation, not a compatibility
// prefix from the wire handshake.
func (s *Session) DatabaseToolsServerVersion() string { return s.serverVersion }

// DatabaseToolsDumpPreflight rejects native transaction-id history that the
// selected logical utility cannot port without the server transaction registry.
func (s *Session) DatabaseToolsDumpPreflight(ctx context.Context) error {
	blocked := false
	var metadataReason string
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		var e error
		metadataReason, e = s.databaseToolsNativeMetadata(ctx)
		if e != nil {
			return e
		}
		if metadataReason != "" {
			return nil
		}

		result, err := s.work.client.Execute(`SELECT COUNT(*) FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON BINARY t.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY t.TABLE_NAME=BINARY c.TABLE_NAME WHERE BINARY c.TABLE_SCHEMA=BINARY DATABASE() AND t.TABLE_TYPE='SYSTEM VERSIONED' AND c.DATA_TYPE='bigint' AND c.IS_GENERATED='ALWAYS' AND BINARY c.GENERATION_EXPRESSION IN (BINARY 'ROW START',BINARY 'ROW END')`)
		if err != nil {
			return err
		}
		defer result.Close()
		if result.RowNumber() != 1 || result.ColumnNumber() != 1 {
			return errors.New("incomplete native history metadata")
		}
		count, err := result.GetUint(0, 0)
		if err != nil {
			return err
		}
		blocked = count > 0
		return nil
	})
	if response.Type == "error" {
		return &adapter.ConnectionError{Category: "validation", Message: "The complete native history backup scope could not be verified. No dump was authorized."}
	}
	if metadataReason != "" {
		return &adapter.ConnectionError{Category: "unsupported", Message: metadataReason}
	}
	if blocked {
		return &adapter.ConnectionError{Category: "unsupported", Message: "The selected MariaDB dump utility supports timestamp-based system history only. This database contains transaction-precise history; use a coordinated server-level backup that preserves mysql.transaction_registry."}
	}
	return nil
}

// DatabaseToolsPeerFingerprint binds a utility to this encrypted physical
// preflight certificate. Only verify-ca/full modes establish certificate trust.
func (s *Session) DatabaseToolsPeerFingerprint() string { return s.work.peerFingerprint }
