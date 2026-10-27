// Package mcpbridge exposes only the application-approved local agent surface.
// It never opens a database, reads profiles or resolves credentials itself.
package mcpbridge

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"

	"github.com/google/uuid"
)

const MaxRequestBytes = 128 * 1024
const MaxResponseBytes = 1024 * 1024

var errUnavailable = errors.New("DBeer agent access is unavailable. Open DBeer and approve the client in the application.")
var errTransport = errors.New("The DBeer agent connection closed. Reconnect and approve access in DBeer.")
var errBusy = errors.New("Too many DBeer agent operations are pending.")

type request struct {
	ID             string `json:"id"`
	Method         string `json:"method"`
	ClientName     string `json:"clientName,omitempty"`
	ProfileID      string `json:"profileId,omitempty"`
	SQL            string `json:"sql,omitempty"`
	QueryID        string `json:"queryId,omitempty"`
	Kind           string `json:"kind,omitempty"`
	Schema         string `json:"schema,omitempty"`
	Object         string `json:"object,omitempty"`
	MaxRows        int    `json:"maxRows,omitempty"`
	TimeoutSeconds int    `json:"timeoutSeconds,omitempty"`
}

type Connection struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Engine   string `json:"engine"`
	ReadOnly bool   `json:"readOnly"`
}

type Column struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Encoding string `json:"encoding,omitempty"`
}

type Result struct {
	Columns    []Column    `json:"columns"`
	Rows       [][]*string `json:"rows"`
	CommandTag string      `json:"commandTag"`
	RowCount   int64       `json:"rowCount"`
	Truncated  bool        `json:"truncated"`
}

type response struct {
	ID          string       `json:"id"`
	OK          bool         `json:"ok"`
	Error       string       `json:"error,omitempty"`
	Connections []Connection `json:"connections,omitempty"`
	Results     []Result     `json:"results,omitempty"`
	QueryID     string       `json:"queryId,omitempty"`
}

type outgoing struct {
	id   string
	data []byte
}

type bridge struct {
	conn     net.Conn
	mu       sync.Mutex
	pending  map[string]chan response
	closed   chan struct{}
	once     sync.Once
	ordinary chan outgoing
	controls chan outgoing
}

func newBridge(conn net.Conn) *bridge {
	b := &bridge{conn: conn, pending: make(map[string]chan response), closed: make(chan struct{}), ordinary: make(chan outgoing, 16), controls: make(chan outgoing, 8)}
	go b.read()
	go b.write()
	return b
}

func (b *bridge) close() {
	b.once.Do(func() {
		close(b.closed)
		_ = b.conn.Close()
	})
}

func (b *bridge) call(ctx context.Context, command request) (response, error) {
	command.ID = uuid.NewString()
	encoded, err := json.Marshal(command)
	if err != nil || len(encoded) > MaxRequestBytes {
		return response{}, errors.New("The DBeer agent request exceeds its size limit.")
	}
	result := make(chan response, 1)
	b.mu.Lock()
	if len(b.pending) >= 32 || command.Method != "cancel" && len(b.pending) >= 24 {
		b.mu.Unlock()
		return response{}, errBusy
	}
	b.pending[command.ID] = result
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.pending, command.ID)
		b.mu.Unlock()
	}()
	queue := b.ordinary
	if command.Method == "cancel" {
		queue = b.controls
	}
	select {
	case <-b.closed:
		return response{}, errTransport
	case <-ctx.Done():
		return response{}, errors.New("The DBeer agent operation was cancelled.")
	case queue <- outgoing{id: command.ID, data: append(encoded, '\n')}:
	default:
		return response{}, errBusy
	}
	select {
	case reply := <-result:
		if !reply.OK {
			if reply.Error == "" || len(reply.Error) > 1024 {
				return response{}, errors.New("DBeer denied this agent operation.")
			}
			return response{}, errors.New(reply.Error)
		}
		return reply, nil
	case <-b.closed:
		return response{}, errTransport
	case <-ctx.Done():
		// Control admission and socket output are independent of MCP stdout.
		// A cancelled call must not wait for its client to consume SQL results.
		// Retire unsent work before publishing priority cancellation: otherwise
		// the cancel could overtake a queued query that is still eligible to send.
		b.mu.Lock()
		delete(b.pending, command.ID)
		b.mu.Unlock()
		if command.Method == "query" || command.Method == "catalog" {
			go func() {
				cancelCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				_, _ = b.call(cancelCtx, request{Method: "cancel", QueryID: command.QueryID})
			}()
		}
		return response{}, errors.New("The DBeer agent operation was cancelled. Verify its outcome in DBeer before retrying writes.")
	}
}

func (b *bridge) read() {
	defer b.close()
	scanner := bufio.NewScanner(b.conn)
	scanner.Buffer(make([]byte, 4096), MaxResponseBytes+1)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) > MaxResponseBytes {
			return
		}
		var reply response
		if json.Unmarshal(line, &reply) != nil || reply.ID == "" {
			return
		}
		b.mu.Lock()
		pending := b.pending[reply.ID]
		b.mu.Unlock()
		if pending != nil {
			select {
			case pending <- reply:
			default:
				return
			}
		}
	}
}

func (b *bridge) write() {
	defer b.close()
	for {
		var item outgoing
		// Stop/cancellation has a reserved queue and goes before new work.
		select {
		case <-b.closed:
			return
		case item = <-b.controls:
		default:
			select {
			case <-b.closed:
				return
			case item = <-b.controls:
			case item = <-b.ordinary:
			}
		}
		b.mu.Lock()
		pending := b.pending[item.id]
		b.mu.Unlock()
		if pending == nil {
			continue
		}
		_ = b.conn.SetWriteDeadline(time.Now().Add(time.Second))
		if _, err := b.conn.Write(item.data); err != nil {
			return
		}
	}
}
