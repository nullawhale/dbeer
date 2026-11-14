package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"fmt"
)

func (r *mariaSchemaCapture) openMetadataControl(owner []*string) (*connection, func(), error) {
	invalid := func() (*connection, func(), error) {
		return nil, nil, fmt.Errorf("%w: native metadata connection binding", sc.ErrInvalid)
	}
	if r.s.openControl == nil || len(owner) != 3 {
		return invalid()
	}
	ctx, cancel := context.WithTimeout(r.ctx, RecoveryTimeout)
	control, e := r.s.openControl(ctx)
	if e != nil {
		cancel()
		return invalid()
	}
	if control == nil || control == r.s.work || control.client == nil || control.client == r.s.work.client || control.transport == nil {
		cancel()
		return invalid()
	}
	stop := context.AfterFunc(ctx, func() { _ = control.transport.Close() })
	cleanup := func() { stop(); cancel(); _ = control.transport.Close() }
	if deadline, ok := ctx.Deadline(); ok {
		_ = control.transport.SetDeadline(deadline)
	}
	identity, e := serverIdentity(control)
	if e != nil || identity != r.s.serverIdentity || control.client.GetConnectionID() == r.s.connectionID {
		cleanup()
		return invalid()
	}
	result, e := control.client.Execute("SELECT CURRENT_USER(),CURRENT_ROLE(),@@character_set_client,@@character_set_connection,@@character_set_results")
	if e != nil {
		cleanup()
		return invalid()
	}
	same := result.RowNumber() == 1 && result.ColumnNumber() == 5
	if same {
		for i := 0; i < 2; i++ {
			null, e := result.IsNull(0, i)
			if e != nil || null != (owner[i] == nil) {
				same = false
				break
			}
			if !null {
				value, e := result.GetString(0, i)
				if e != nil || value != *owner[i] {
					same = false
					break
				}
			}
		}
	}
	if same {
		for i := 2; i < 5; i++ {
			value, e := result.GetString(0, i)
			if e != nil || value != "utf8mb4" {
				same = false
				break
			}
		}
	}
	result.Close()
	if !same {
		cleanup()
		return invalid()
	}
	return control, cleanup, nil
}
