package mysql

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

// A cancellation gate surrounds each statement, so a late KILL cannot hit the
// ROLLBACK that establishes a known outcome for the complete Apply batch.
type changeExecution struct {
	session          *Session
	ctx              context.Context
	gate             sync.Mutex
	active           bool
	stop, done       chan struct{}
	once             sync.Once
	recoveryDeadline time.Time
}

func (session *Session) newChangeExecution(ctx context.Context) *changeExecution {
	execution := &changeExecution{session: session, ctx: ctx, stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(execution.done)
		select {
		case <-execution.stop:
			return
		case <-ctx.Done():
		}
		execution.recoveryDeadline = time.Now().Add(RecoveryTimeout)
		_ = session.work.transport.SetDeadline(execution.recoveryDeadline)
		controlCtx, cancel := context.WithDeadline(context.Background(), execution.recoveryDeadline)
		defer cancel()
		control, err := session.openControl(controlCtx)
		if err == nil {
			defer control.transport.Close()
			var uuid string
			uuid, err = serverIdentity(control)
			if err == nil && (uuid != session.serverUUID || control.client.GetConnectionID() == session.connectionID) {
				err = errors.New("cancellation identity mismatch")
			}
		}
		execution.gate.Lock()
		defer execution.gate.Unlock()
		if !execution.active {
			return
		}
		if err == nil {
			var target *wire.Result
			target, err = control.client.Execute(fmt.Sprintf("SELECT ID FROM information_schema.PROCESSLIST WHERE ID=%d", session.connectionID))
			if err == nil {
				if target.RowNumber() != 1 {
					err = errors.New("cancellation target missing")
				}
				target.Close()
			}
		}
		if err == nil {
			var killed *wire.Result
			killed, err = control.client.Execute(fmt.Sprintf("KILL QUERY %d", session.connectionID))
			if killed != nil {
				killed.Close()
			}
		}
		if err != nil {
			session.Close()
		}
	}()
	return execution
}

func (execution *changeExecution) finish() {
	execution.once.Do(func() { close(execution.stop) })
	<-execution.done
}

func (execution *changeExecution) query(sql string, args ...any) (*wire.Result, error) {
	if err := execution.ctx.Err(); err != nil {
		return nil, err
	}
	execution.gate.Lock()
	if err := execution.ctx.Err(); err != nil {
		execution.gate.Unlock()
		return nil, err
	}
	execution.active = true
	execution.gate.Unlock()
	result, err := execution.session.work.client.Execute(sql, args...)
	execution.gate.Lock()
	execution.active = false
	execution.gate.Unlock()
	return result, err
}

func (session *Session) ExecuteChanges(ctx context.Context, command protocol.Command) protocol.Response {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.closed.Load() {
		return session.unknown(command)
	}
	if command.Changes == nil || !command.Changes.Valid() || (command.Type != "changes.preview" && command.Type != "changes.apply") {
		return session.changeError(command, ctx, editFailure("validation", "Invalid table changes."))
	}
	if session.TransactionStatus() != "idle" {
		return session.changeError(command, ctx, editFailure("validation", "Apply requires a separate idle session. SQL tab transactions are left untouched."))
	}
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	if deadline, ok := ctx.Deadline(); ok {
		_ = session.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	execution := session.newChangeExecution(ctx)
	defer execution.finish()
	defer func() {
		if !session.closed.Load() {
			_ = session.work.transport.SetDeadline(time.Time{})
		}
	}()
	request := *command.Changes
	metadata, err := session.editMetadata(request)
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	plans, err := planChanges(metadata, request)
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	if command.Type == "changes.preview" {
		if ctx.Err() != nil {
			return session.changeError(command, ctx, ctx.Err())
		}
		return previewChanges(command, plans)
	}
	// Strict conversion makes type/length violations fail the entire batch even
	// if the server's default sql_mode permits lossy coercions.
	result, err := execution.query("SET SESSION sql_mode=CONCAT_WS(',',@@SESSION.sql_mode,'STRICT_ALL_TABLES'), explicit_defaults_for_timestamp=ON, time_zone='+00:00'")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	result, err = execution.query("BEGIN")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	var names []string
	for _, column := range metadata.columns {
		names = append(names, QuoteIdentifier(column.name))
	}
	result, err = execution.query("SELECT " + strings.Join(names, ", ") + " FROM " + metadata.qualified + " LIMIT 0 FOR UPDATE")
	if result != nil {
		result.Close()
	}
	if err == nil {
		metadata, err = session.editMetadata(request)
	}
	if err == nil {
		plans, err = planChanges(metadata, request)
	}
	for index, plan := range plans {
		if err != nil {
			break
		}
		if ctx.Err() != nil {
			err = ctx.Err()
			break
		}
		if plan.kind != "insert" {
			var args []any
			args, err = bindCells(plan.keys)
			if err == nil {
				result, err = execution.query(plan.lockSQL, args...)
			}
			if err == nil {
				if result.RowNumber() != 1 || !sameSnapshot(metadata, result, plan.original, plan.storageToken) {
					err = editFailure("conflict", "The row changed or disappeared. Reload data and review the local edits.")
				}
				result.Close()
				if err == nil && session.afterRowLock != nil {
					session.afterRowLock(index)
				}
			}
		}
		if err == nil {
			var args []any
			args, err = bindCells(plan.parameters)
			if err == nil {
				result, err = execution.query(plan.sql, args...)
				if result != nil {
					if err == nil && result.Warnings != 0 {
						err = editFailure("validation", "The server reported a value conversion warning. Review the values before applying them.")
					}
					result.Close()
				}
			}
		}
	}
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		return session.rollbackChanges(execution, command, err)
	}
	commit := func() error {
		result, err := execution.query("COMMIT")
		if result != nil {
			result.Close()
		}
		return err
	}
	if session.commitOverride != nil {
		err = session.commitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		execution.finish()
		session.Close()
		response := protocol.ErrorResponse(command, "connection", "Commit confirmation was lost. Changes may have been committed. Verify the table before another Apply.")
		response.OutcomeUnknown = true
		return response
	}
	execution.finish()
	session.updateTransaction()
	return applySuccess(command, len(plans))
}

func (session *Session) rollbackChanges(execution *changeExecution, command protocol.Command, cause error) protocol.Response {
	execution.finish()
	deadline := time.Now().Add(RecoveryTimeout)
	if !execution.recoveryDeadline.IsZero() && execution.recoveryDeadline.Before(deadline) {
		deadline = execution.recoveryDeadline
	}
	_ = session.work.transport.SetDeadline(deadline)
	if session.closed.Load() {
		return session.unknown(command)
	}
	result, err := session.work.client.Execute("ROLLBACK")
	if result != nil {
		result.Close()
	}
	if err != nil {
		session.Close()
		return session.unknown(command)
	}
	session.updateTransaction()
	return session.changeError(command, execution.ctx, cause)
}

func (session *Session) changeError(command protocol.Command, ctx context.Context, err error) protocol.Response {
	var local *adapter.ConnectionError
	if errors.As(err, &local) {
		response := protocol.ErrorResponse(command, local.Category, local.Message)
		response.Connected = !session.closed.Load()
		response.TransactionStatus = session.TransactionStatus()
		return response
	}
	var server *wire.MyError
	if errors.As(err, &server) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return session.queryError(command, ctx, err)
	}
	session.Close()
	return session.unknown(command)
}

func sameSnapshot(metadata editMetadata, result *wire.Result, original []protocol.CellValue, storageToken string) bool {
	storageFields := len(mysqlStorageColumns(metadata))
	if result.RowNumber() != 1 || len(result.Fields)-storageFields != len(original) || len(result.Values[0])-storageFields != len(original) {
		return false
	}
	if storageToken != "" {
		actual, err := mysqlStorageToken(result.Values[0][len(original):])
		if err != nil || actual != storageToken {
			return false
		}
	}
	for index, value := range result.Values[0][:len(original)] {
		expected := original[index]
		if value.Type == wire.FieldValueTypeNull {
			if expected.Kind != "null" {
				return false
			}
			continue
		}
		if expected.Value == nil {
			return false
		}
		kind := metadata.columns[index].dataType
		if storageToken != "" && (kind == "float" || kind == "double" || kind == "timestamp") {
			continue
		}
		if storageToken == "" && (kind == "float" || kind == "timestamp" || kind == "double" && strings.Contains(metadata.columns[index].nativeType, "(")) {
			return false
		}
		if storageToken == "" && (metadata.columns[index].ambiguousEmptyEnum && *expected.Value == "" || metadata.columns[index].ambiguousEnum || metadata.columns[index].ambiguousSet) {
			// The displayed empty string cannot prove whether the original was
			// member '' or the legacy error member 0. Never overwrite that row
			// using an original snapshot that does not contain the ordinal/mask.
			// SET drops an empty member's bit even in nonempty display strings.
			// Duplicate members and commas in SET labels also hide storage bits.
			return false
		}
		if binaryColumn(result.Fields[index]) {
			if expected.Kind != "binary" {
				return false
			}
			decoded, err := base64.StdEncoding.DecodeString(*expected.Value)
			if err != nil || !bytes.Equal(decoded, value.AsString()) {
				return false
			}
			continue
		}
		if expected.Kind != "text" {
			return false
		}
		var actual string
		switch value.Type {
		case wire.FieldValueTypeString:
			actual = string(value.AsString())
		case wire.FieldValueTypeUnsigned:
			actual = strconv.FormatUint(value.AsUint64(), 10)
		case wire.FieldValueTypeSigned:
			actual = strconv.FormatInt(value.AsInt64(), 10)
		case wire.FieldValueTypeFloat:
			actual = strconv.FormatFloat(value.AsFloat64(), 'g', -1, 64)
		}
		if kind == "float" || kind == "double" {
			bits := 64
			if kind == "float" {
				bits = 32
			}
			left, e1 := strconv.ParseFloat(actual, bits)
			right, e2 := strconv.ParseFloat(*expected.Value, bits)
			if e1 != nil || e2 != nil || left != right {
				return false
			}
			continue
		}
		if kind == "datetime" || kind == "timestamp" || kind == "time" {
			actual = trimTemporal(actual)
			if actual != trimTemporal(*expected.Value) {
				return false
			}
			continue
		}
		if actual != *expected.Value {
			return false
		}
	}
	return true
}

func trimTemporal(value string) string {
	if strings.Contains(value, ".") {
		value = strings.TrimSuffix(strings.TrimRight(value, "0"), ".")
	}
	return value
}
