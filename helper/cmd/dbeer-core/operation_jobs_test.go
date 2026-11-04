package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
)

type operationPipeSession struct{ applies, opens, closed *atomic.Int32 }

func (s *operationPipeSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("operation jobs must not execute user SQL")
}
func (s *operationPipeSession) Close()                                  { s.closed.Add(1) }
func (s *operationPipeSession) TransactionStatus() string               { return "idle" }
func (s *operationPipeSession) SetReadOnly(context.Context, bool) error { return nil }
func (s *operationPipeSession) DatabaseToolsServerVersion() string      { return "17.6" }
func (s *operationPipeSession) TransferDescribe(context.Context, string, string) (datatransfer.Description, error) {
	return datatransfer.Description{}, errors.New("unexpected source description")
}
func (s *operationPipeSession) TransferCapture(context.Context, string, string, string, func([]protocol.CellValue) error) (datatransfer.Description, error) {
	return datatransfer.Description{}, errors.New("unexpected source capture")
}
func (s *operationPipeSession) TransferPreview(context.Context, string, string, []protocol.TransferColumn) (string, string, error) {
	return "CREATE TABLE reviewed_fixture(id BIGINT);", "fixture-server", nil
}
func (s *operationPipeSession) TransferApply(ctx context.Context, _, _, identity string, _ []protocol.TransferColumn, read datatransfer.RowReader, progress func(int64)) (datatransfer.Result, error) {
	if identity != "fixture-server" {
		return datatransfer.Result{}, datatransfer.ErrChanged
	}
	s.applies.Add(1)
	var rows int64
	for {
		if err := ctx.Err(); err != nil {
			return datatransfer.Result{}, err
		}
		_, err := read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return datatransfer.Result{}, err
		}
		rows++
		progress(rows)
	}
	return datatransfer.Result{Rows: rows, TableCreated: true}, nil
}
func operationConnection() protocol.Connection {
	return protocol.Connection{Engine: "postgresql", Host: "fixture.invalid", Port: 5432, Database: "fixture", User: "reader", SSLMode: "disable"}
}
func operationUtility(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pg_dump")
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'pg_dump (PostgreSQL) 17.6'; exit 0; fi\nprintf 'reviewed-dump'\n"
	if os.WriteFile(path, []byte(script), 0700) != nil {
		t.Fatal("cannot create utility protocol fixture")
	}
	return path
}

func TestOperationJobsMainRoutesTransferAndDatabaseTools(t *testing.T) {
	input, writer := io.Pipe()
	reader, output := io.Pipe()
	defer input.Close()
	defer writer.Close()
	defer reader.Close()
	defer output.Close()
	var opens, closed, applies atomic.Int32
	done := make(chan error, 1)
	go func() {
		done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
			opens.Add(1)
			return &operationPipeSession{opens: &opens, closed: &closed, applies: &applies}, nil
		})
	}()
	responses := make(chan protocol.Response, 16)
	go func() {
		defer close(responses)
		decoder := json.NewDecoder(reader)
		for {
			var response protocol.Response
			if decoder.Decode(&response) != nil {
				return
			}
			responses <- response
		}
	}()
	encoder := json.NewEncoder(writer)
	counter := 0
	send := func(command protocol.Command) {
		t.Helper()
		counter++
		command.RequestID = "operation-" + strconv.Itoa(counter)
		if encoder.Encode(command) != nil {
			t.Fatal("cannot send operation protocol command")
		}
	}
	receive := func() protocol.Response {
		t.Helper()
		select {
		case response, ok := <-responses:
			if !ok {
				t.Fatal("operation protocol closed unexpectedly")
			}
			return response
		case <-time.After(4 * time.Second):
			t.Fatal("operation protocol response timed out")
			return protocol.Response{}
		}
	}
	send(protocol.Command{Type: "hello", ProtocolVersion: protocol.Version})
	hello := receive()
	if hello.Type != "hello.ack" || !slices.Contains(hello.Capabilities, protocol.DataTransferCapability) || !slices.Contains(hello.Capabilities, protocol.DatabaseToolsCapability) {
		t.Fatal("new job capabilities were not advertised")
	}
	c := operationConnection()
	value := "7"
	request := protocol.TransferRequest{Mode: "csv", Target: &protocol.TransferEndpoint{Connection: c, Schema: "public", Table: "reviewed_fixture"}, Headers: []string{"id"}, Rows: [][]protocol.CellValue{{{Kind: "text", Value: &value}}}}
	pollTransfer := func(jobID, state string) protocol.TransferReply {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			send(protocol.Command{Type: "transfer.status", Transfer: &protocol.TransferRequest{JobID: jobID}})
			reply := receive()
			if reply.Transfer == nil || !reply.Transfer.Valid() {
				t.Fatal("transfer status lost its typed payload")
			}
			if reply.Transfer.State == state {
				return *reply.Transfer
			}
			if reply.Transfer.State == "failed" {
				t.Fatal("routed transfer failed")
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatal("routed transfer did not reach expected state")
		return protocol.TransferReply{}
	}
	send(protocol.Command{Type: "transfer.describe", Transfer: &request})
	description := receive()
	if description.Transfer == nil {
		t.Fatal("transfer describe was not routed")
	}
	described := pollTransfer(description.Transfer.JobID, "described")
	if opens.Load() != 0 {
		t.Fatal("CSV type description opened a database")
	}
	request.Columns = described.Columns
	send(protocol.Command{Type: "transfer.preview", Transfer: &request})
	prepared := receive()
	if prepared.Transfer == nil {
		t.Fatal("transfer preview was not routed")
	}
	ready := pollTransfer(prepared.Transfer.JobID, "ready")
	send(protocol.Command{Type: "transfer.apply", Transfer: &protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}})
	accepted := receive()
	if accepted.Transfer == nil {
		t.Fatal("reviewed transfer apply was not routed")
	}
	completed := pollTransfer(ready.JobID, "completed")
	if completed.RowsWritten != 1 || !completed.TableCreated || applies.Load() != 1 {
		t.Fatal("transfer did not apply its reviewed rows exactly once")
	}
	for _, id := range []string{described.JobID, ready.JobID} {
		send(protocol.Command{Type: "transfer.close", Transfer: &protocol.TransferRequest{JobID: id}})
		reply := receive()
		if reply.Transfer == nil || reply.Transfer.State != "closed" {
			t.Fatal("transfer close was not routed")
		}
	}
	path := filepath.Join(t.TempDir(), "backup.dump")
	send(protocol.Command{Type: "dbtools.preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "dump", Format: "custom", Path: path, ToolPath: operationUtility(t)}})
	preview := receive()
	if preview.DatabaseTools == nil || preview.DatabaseTools.State != "prepared" {
		t.Fatal("utility preview was not routed")
	}
	send(protocol.Command{Type: "dbtools.start", DatabaseTools: &protocol.DatabaseToolsRequest{PlanID: preview.DatabaseTools.PlanID, ApprovalToken: preview.DatabaseTools.ApprovalToken}})
	job := receive()
	if job.DatabaseTools == nil {
		t.Fatal("utility start was not routed")
	}
	deadline := time.Now().Add(4 * time.Second)
	published := false
	for time.Now().Before(deadline) {
		send(protocol.Command{Type: "dbtools.status", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: job.DatabaseTools.JobID}})
		status := receive()
		if status.DatabaseTools == nil || !status.DatabaseTools.Valid(status.Type) {
			t.Fatal("utility status lost its validated payload")
		}
		if status.DatabaseTools.State == "completed" {
			published = status.DatabaseTools.OutputPublished
			break
		}
		if status.DatabaseTools.State == "failed" {
			t.Fatal("routed utility failed")
		}
		time.Sleep(5 * time.Millisecond)
	}
	data, err := os.ReadFile(path)
	if !published || err != nil || string(data) != "reviewed-dump" {
		t.Fatal("routed utility failed to publish its reviewed dump")
	}
	send(protocol.Command{Type: "dbtools.close", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: job.DatabaseTools.JobID}})
	if reply := receive(); reply.DatabaseTools == nil || reply.DatabaseTools.State != "closed" {
		t.Fatal("utility close was not routed")
	}
	send(protocol.Command{Type: "shutdown"})
	if receive().Type != "shutdown.ack" {
		t.Fatal("operation helper shutdown acknowledgement missing")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal("operation helper failed during shutdown")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("operation helper did not shut down")
	}
	if opens.Load() != closed.Load() {
		t.Fatal("operation helper leaked a dedicated database session")
	}
}

func TestOperationJobsConcurrentCloseUnblocksBoundedOutput(t *testing.T) {
	var opens atomic.Int32
	jobs, err := newOperationJobs(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opens.Add(1)
		return nil, errors.New("no database work expected")
	}, nil)
	if err != nil {
		t.Fatal("cannot create operation jobs")
	}
	output := make(chan protocol.Response)
	stop := make(chan struct{})
	defer close(stop)
	for index := range 4 {
		command := protocol.Command{Type: "transfer.status", RequestID: strconv.Itoa(index), Transfer: &protocol.TransferRequest{JobID: "missing"}}
		if index%2 == 0 {
			command.Type = "dbtools.status"
			command.Transfer = nil
			command.DatabaseTools = &protocol.DatabaseToolsRequest{JobID: "missing"}
		}
		if !jobs.dispatch(command, output, stop) {
			t.Fatal("bounded operation admission rejected its available capacity")
		}
	}
	if jobs.dispatch(protocol.Command{Type: "dbtools.status", RequestID: "overflow", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: "missing"}}, output, stop) {
		t.Fatal("operation admission exceeded its fixed capacity")
	}
	var closing sync.WaitGroup
	closing.Add(8)
	for range 8 {
		go func() { defer closing.Done(); jobs.Close() }()
	}
	done := make(chan struct{})
	go func() { closing.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("concurrent operation close waited for blocked output")
	}
	if jobs.dispatch(protocol.Command{}, output, stop) || opens.Load() != 0 {
		t.Fatal("closed operations accepted work or touched a database")
	}
}

func TestOperationJobsStatusAndCancellationRetainAdmissionDuringPreviews(t *testing.T) {
	jobs, err := newOperationJobs(func(context.Context, protocol.Connection) (adapter.Session, error) {
		t.Error("an invalid preview opened a database")
		return nil, errors.New("unexpected database open")
	}, nil)
	if err != nil {
		t.Fatal("cannot create operation jobs")
	}
	defer jobs.Close()
	stop := make(chan struct{})
	defer close(stop)
	blockedOutput := make(chan protocol.Response)
	for index := range 4 {
		if !jobs.dispatch(protocol.Command{Type: "dbtools.preview", RequestID: strconv.Itoa(index)}, blockedOutput, stop) {
			t.Fatal("preview did not occupy its available admission slot")
		}
	}
	for _, kind := range []string{"dbtools.status", "dbtools.cancel", "transfer.status", "transfer.cancel"} {
		command := protocol.Command{Type: kind, RequestID: "control", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: "missing"}}
		if strings.HasPrefix(kind, "transfer.") {
			command.DatabaseTools = nil
			command.Transfer = &protocol.TransferRequest{JobID: "missing"}
		}
		output := make(chan protocol.Response, 1)
		if !jobs.dispatch(command, output, stop) {
			t.Fatal("blocked previews prevented a status or cancellation request")
		}
		select {
		case <-output:
		case <-time.After(time.Second):
			t.Fatal("status or cancellation waited for blocked preview output")
		}
	}
}

func TestOperationJobsEOFAndShutdownCancelBlockedProbeWithoutOutput(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		name := "EOF"
		if shutdown {
			name = "shutdown"
		}
		t.Run(name, func(t *testing.T) {
			input, writer := io.Pipe()
			reader, output := io.Pipe()
			defer input.Close()
			defer writer.Close()
			defer reader.Close()
			defer output.Close()
			opened, cancelled := make(chan struct{}), make(chan struct{})
			done := make(chan error, 1)
			go func() {
				done <- runWithFactory(input, output, func(ctx context.Context, _ protocol.Connection) (adapter.Session, error) {
					close(opened)
					<-ctx.Done()
					close(cancelled)
					return nil, ctx.Err()
				})
			}()
			encoder := json.NewEncoder(writer)
			c := operationConnection()
			for _, command := range []protocol.Command{{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version}, {Type: "dbtools.preview", RequestID: "probe", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "dump", Format: "custom", Path: filepath.Join(t.TempDir(), "dump"), ToolPath: operationUtility(t)}}} {
				if encoder.Encode(command) != nil {
					t.Fatal("cannot send blocked-probe fixture")
				}
			}
			select {
			case <-opened:
			case <-time.After(4 * time.Second):
				t.Fatal("blocked output prevented utility probe admission")
			}
			if shutdown {
				if encoder.Encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"}) != nil {
					t.Fatal("cannot send operation shutdown")
				}
			} else {
				writer.Close()
			}
			select {
			case <-cancelled:
			case <-time.After(2 * time.Second):
				t.Fatal("blocked output hid operation cancellation")
			}
			reader.Close()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("operation helper did not exit after failed output transport")
			}
		})
	}
}
