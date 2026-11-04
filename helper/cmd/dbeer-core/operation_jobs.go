package main

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/dbtools"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

// Admission is separate from SQL-session owners so a long file probe, transfer
// or child process cannot hide cancellation of unrelated SQL tabs.
type operationJobs struct {
	transfer  *datatransfer.Manager
	tools     *dbtools.Manager
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
	tools, err := dbtools.New(open, dbtools.Options{Root: os.Getenv("DBEER_DATABASE_TOOLS_ROOT"), PrepareConnection: prepareToolConnection(tunnels)})
	if err != nil {
		transfers.Close()
		return nil, err
	}
	return &operationJobs{transfer: transfers, tools: tools, slots: make(chan struct{}, 4), done: make(chan struct{})}, nil
}
func (jobs *operationJobs) Close() {
	jobs.closeOnce.Do(func() {
		jobs.mu.Lock()
		jobs.closed = true
		close(jobs.done)
		jobs.mu.Unlock()
		jobs.transfer.Close()
		jobs.tools.Close()
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
		var response protocol.Response
		if strings.HasPrefix(command.Type, "transfer.") {
			response = jobs.transfer.Handle(command)
		} else {
			response = jobs.tools.Handle(command)
		}
		select {
		case output <- response:
		case <-stop:
		case <-jobs.done:
		}
	}()
	return true
}

func prepareToolConnection(tunnels *sshtunnel.Manager) dbtools.PrepareConnection {
	return func(ctx context.Context, settings protocol.Connection) (dbtools.PreparedConnection, error) {
		password, err := credential.Password(ctx, settings)
		if err != nil {
			return dbtools.PreparedConnection{}, err
		}
		settings.Password, settings.PasswordCommand = password, nil
		prepared := dbtools.PreparedConnection{Connection: settings, Host: settings.Host, Port: settings.Port}
		if settings.SSH == nil {
			return prepared, nil
		}
		if tunnels == nil {
			return prepared, errors.New("SSH is unavailable for database utilities.")
		}
		lease, err := tunnels.Acquire(ctx, settings.SSH)
		if err != nil {
			return prepared, safeSSHError(err)
		}
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			lease.Close()
			return prepared, errors.New("Cannot prepare the private database utility transport.")
		}
		lifetime, cancel := context.WithCancel(context.Background())
		forward := &toolForward{listener: listener, lease: lease, done: make(chan struct{}), cancel: cancel, connections: map[net.Conn]bool{}}
		prepared.Host, prepared.HostAddr, prepared.Port = settings.Host, "127.0.0.1", listener.Addr().(*net.TCPAddr).Port
		if settings.DatabaseEngine() == "mysql" {
			prepared.Host = "127.0.0.1"
		}
		prepared.Close, prepared.Done = forward.close, forward.done
		forward.workers.Add(1)
		go forward.accept(lifetime, net.JoinHostPort(settings.Host, strconv.Itoa(settings.Port)))
		go func() {
			select {
			case <-lease.Done():
				forward.close()
			case <-forward.done:
			}
		}()
		return prepared, nil
	}
}

type toolForward struct {
	listener    net.Listener
	lease       *sshtunnel.Lease
	done        chan struct{}
	cancel      context.CancelFunc
	once        sync.Once
	mu          sync.Mutex
	connections map[net.Conn]bool
	workers     sync.WaitGroup
}

func (forward *toolForward) close() {
	forward.once.Do(func() {
		close(forward.done)
		forward.cancel()
		forward.listener.Close()
		forward.mu.Lock()
		for connection := range forward.connections {
			connection.Close()
		}
		forward.mu.Unlock()
		forward.lease.Close()
	})
}
func (forward *toolForward) accept(ctx context.Context, target string) {
	defer forward.workers.Done()
	for {
		local, err := forward.listener.Accept()
		if err != nil {
			return
		}
		forward.mu.Lock()
		select {
		case <-forward.done:
			local.Close()
			forward.mu.Unlock()
			return
		default:
		}
		forward.connections[local] = true
		forward.mu.Unlock()
		forward.workers.Add(1)
		go func() {
			defer forward.workers.Done()
			defer func() { local.Close(); forward.mu.Lock(); delete(forward.connections, local); forward.mu.Unlock() }()
			remote, err := forward.lease.DialContext(ctx, "tcp", target)
			if err != nil {
				return
			}
			defer remote.Close()
			forward.mu.Lock()
			select {
			case <-forward.done:
				forward.mu.Unlock()
				return
			default:
			}
			forward.connections[remote] = true
			forward.mu.Unlock()
			defer func() { forward.mu.Lock(); delete(forward.connections, remote); forward.mu.Unlock() }()
			finished := make(chan struct{})
			go func() { io.Copy(remote, local); remote.Close(); close(finished) }()
			io.Copy(local, remote)
			local.Close()
			<-finished
		}()
	}
}
