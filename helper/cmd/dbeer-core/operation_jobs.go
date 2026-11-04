package main

import (
	"os"
	"sync"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

// Admission is separate from SQL-session owners so a long file probe, transfer
// or child process cannot hide cancellation of unrelated SQL tabs.
type operationJobs struct {
	transfer  *datatransfer.Manager
	mu        sync.Mutex
	closed    bool
	closeOnce sync.Once
	done      chan struct{}
	workers   sync.WaitGroup
	slots     chan struct{}
}

func newOperationJobs(open adapter.OpenFunc, tunnels *sshtunnel.Manager) (*operationJobs, error) {
	transfers, err := datatransfer.New(open, datatransfer.Options{Root: os.Getenv("DBEER_TRANSFER_ROOT")})
	if err != nil {
		return nil, err
	}
	return &operationJobs{transfer: transfers, slots: make(chan struct{}, 4), done: make(chan struct{})}, nil
}
func (jobs *operationJobs) Close() {
	jobs.closeOnce.Do(func() {
		jobs.mu.Lock()
		jobs.closed = true
		close(jobs.done)
		jobs.mu.Unlock()
		jobs.transfer.Close()
		jobs.workers.Wait()
	})
}
func (jobs *operationJobs) dispatch(command protocol.Command, output chan<- protocol.Response, stop <-chan struct{}) bool {
	jobs.mu.Lock()
	defer jobs.mu.Unlock()
	if jobs.closed {
		return false
	}
	select {
	case jobs.slots <- struct{}{}:
	default:
		return false
	}
	jobs.workers.Add(1)
	go func() {
		defer jobs.workers.Done()
		defer func() { <-jobs.slots }()
		response := jobs.transfer.Handle(command)
		select {
		case output <- response:
		case <-stop:
		case <-jobs.done:
		}
	}()
	return true
}
