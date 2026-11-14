package adapter

import (
	"context"
	"errors"

	"dbeer/helper/internal/protocol"
)

func MariaDBTuningOptimizerSQL(setting protocol.MariaDBOptimizerVariant, sql string) string {
	value := "off"
	if setting.IndexConditionPushdown {
		value = "on"
	}
	return "SET STATEMENT optimizer_switch='index_condition_pushdown=" + value + "' FOR\n" + sql
}

func ReadMariaDBOptimizerState(ctx context.Context, physical Session, c protocol.Command) (protocol.MariaDBOptimizerObservation, error) {
	var observation protocol.MariaDBOptimizerObservation
	if physical.TransactionStatus() != "idle" {
		return observation, errors.New("The optimizer observation requires the existing idle owner.")
	}
	c = protocol.Command{Type: "execute", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SQL: "SELECT @@SESSION.optimizer_switch"}
	r := physical.Execute(ctx, c)
	if r.Type != "query.result" || r.OutcomeUnknown || physical.TransactionStatus() != "idle" || ctx.Err() != nil || len(r.Rows) != 1 || len(r.Rows[0]) != 1 || r.Rows[0][0] == nil {
		return observation, errors.New("Current MariaDB optimizer state is unavailable.")
	}
	value, ok := protocol.MariaDBIndexConditionPushdown(*r.Rows[0][0])
	if !ok {
		return observation, errors.New("Current MariaDB optimizer state is unsupported.")
	}
	return protocol.MariaDBOptimizerObservation{IndexConditionPushdown: value, NativeSwitch: *r.Rows[0][0]}, nil
}
