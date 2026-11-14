package mariadb

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

// Each generated statement owns the cancellation target until its response is
// drained. Finish the worker before recovery so a late KILL cannot hit rollback.
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
			var identity string
			identity, err = serverIdentity(control)
			if err == nil && (identity != session.serverIdentity || control.client.GetConnectionID() == session.connectionID) {
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
			killed, err = control.client.Execute(fmt.Sprintf("KILL SOFT QUERY %d", session.connectionID))
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
	result, err, _ := execution.run(sql, args...)
	return result, err
}
func (execution *changeExecution) run(sql string, args ...any) (*wire.Result, error, bool) {
	if err := execution.ctx.Err(); err != nil {
		return nil, err, false
	}
	execution.gate.Lock()
	if err := execution.ctx.Err(); err != nil {
		execution.gate.Unlock()
		return nil, err, false
	}
	execution.active = true
	execution.gate.Unlock()
	result, err := execution.session.work.client.Execute(sql, args...)
	execution.gate.Lock()
	execution.active = false
	execution.gate.Unlock()
	return result, err, true
}

func (session *Session) executeMariaDBChanges(ctx context.Context, command protocol.Command) protocol.Response {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.closed.Load() {
		return session.unknown(command)
	}
	if command.Changes == nil || !command.Changes.Valid() || !mariaDBNameValid(command.Changes.Schema) || !mariaDBNameValid(command.Changes.Table) || (command.Type != "changes.preview" && command.Type != "changes.apply") {
		return session.changeError(command, ctx, editFailure("validation", "Invalid MariaDB table changes."))
	}
	if session.TransactionStatus() != "idle" {
		return session.changeError(command, ctx, editFailure("validation", "Apply requires a separate idle session. SQL-tab transactions remain untouched."))
	}
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	if deadline, ok := ctx.Deadline(); ok {
		_ = session.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	execution := session.newChangeExecution(ctx)
	defer func() {
		execution.finish()
		if !session.closed.Load() {
			_ = session.work.transport.SetDeadline(time.Time{})
		}
	}()
	scope, err := loadMariaDBWriteScope(execution)
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	request := *command.Changes
	metadata, err := session.editMetadata(execution, request)
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	plans, err := planChanges(metadata, request, scope)
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	if command.Type == "changes.preview" {
		if err := scope.verify(execution); err != nil {
			return session.changeError(command, ctx, err)
		}
		return previewChanges(command, plans)
	}
	result, err := execution.query("BEGIN")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return session.changeError(command, ctx, err)
	}
	// Retain the real target's metadata lock before reading the ordered columns
	// again, so a concurrent DDL cannot swap its type/default/key under Apply.
	result, err = execution.query(scope.wrap("SELECT * FROM " + metadata.qualified + " LIMIT 0 FOR UPDATE"))
	if result != nil {
		result.Close()
	}
	if err == nil {
		metadata, err = session.editMetadata(execution, request)
	}
	if err == nil {
		plans, err = planChanges(metadata, request, scope)
	}
	for index, plan := range plans {
		if err != nil {
			break
		}
		if plan.kind != "insert" {
			var args []any
			args, err = bindCells(plan.keys)
			if err == nil {
				result, err = execution.query(plan.lockSQL, args...)
			}
			if err == nil {
				if !sameSnapshot(metadata, result, plan.original, plan.storageToken) {
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
					if err == nil && (result.Warnings != 0 || plan.kind == "insert" && result.AffectedRows != 1 || plan.kind == "delete" && result.AffectedRows != 1 || plan.kind == "update" && result.AffectedRows > 1) {
						err = editFailure("validation", "The server reported a conversion warning or an unexpected affected-row count. The batch was not committed.")
					}
					result.Close()
				}
			}
		}
	}
	if err == nil {
		err = scope.verify(execution)
	}
	if err != nil {
		return session.rollbackChanges(execution, command, err)
	}
	return session.commitRowBatch(execution, command, func() protocol.Response { return applySuccess(command, len(plans)) })
}

func (session *Session) commitRowBatch(execution *changeExecution, command protocol.Command, success func() protocol.Response) protocol.Response {
	var dispatched bool
	commit := func() error {
		result, err, started := execution.run("COMMIT AND NO CHAIN NO RELEASE")
		dispatched = dispatched || started
		if result != nil {
			result.Close()
		}
		return err
	}
	var err error
	if session.commitOverride != nil {
		err = session.commitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		if !dispatched {
			return session.rollbackChanges(execution, command, err)
		}
		execution.finish()
		session.Close()
		response := protocol.ErrorResponse(command, "connection", "COMMIT confirmation was lost. Changes may have been committed. Verify the table before another Apply.")
		response.OutcomeUnknown = true
		return response
	}
	execution.finish()
	session.updateTransaction()
	return success()
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
	result, err := session.work.client.Execute("ROLLBACK AND NO CHAIN NO RELEASE")
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
