package mariadb

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func (s *Session) StructureLoad(ctx context.Context, target tableedit.Target) (tableedit.Baseline, error) {
	var baseline tableedit.Baseline
	var loadErr error
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		baseline, loadErr = s.readMariaDBStructure(target, s.readStructureFacts)
		if loadErr != nil {
			return &adapter.ConnectionError{Category: "validation", Message: loadErr.Error()}
		}
		return nil
	})
	if loadErr != nil {
		return baseline, loadErr
	}
	if response.Type != "query.result" {
		return baseline, tableedit.ErrUnsupported
	}
	return baseline, nil
}
