// Package catalogmetadata retains bounded immutable observations owned by one
// physical service session. Continuations never reread a changing live catalog.
package catalogmetadata

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

const MaxBytes = 64 << 20
const MaxRows = 100000
const MaxCaptures = 32
const Lifetime = 2 * time.Minute
const maxGroupBytes = 128 << 10

var ErrCursor = errors.New("Metadata observation is unavailable or expired. Refresh explicitly.")

type ReadError struct{ Response protocol.Response }

func (e *ReadError) Error() string { return "The metadata connection became unavailable." }

type observation struct {
	collection protocol.CatalogMetadataCollection
	file       *os.File
	offsets    []int64
	bytes      int64
	expires    time.Time
	timer      *time.Timer
	cursors    map[int]string
}
type continuation struct {
	captureID string
	group     int
}
type Store struct {
	mu       sync.Mutex
	captures map[string]*observation
	cursors  map[string]continuation
	closed   bool
}

func token() (string, error) {
	var bytes [24]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", errors.New("Metadata observation identifiers are unavailable.")
	}
	return hex.EncodeToString(bytes[:]), nil
}

func (s *Store) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	for id := range s.captures {
		s.remove(id)
	}
}
func (s *Store) remove(id string) {
	if c := s.captures[id]; c != nil {
		if c.timer != nil {
			c.timer.Stop()
		}
		name := c.file.Name()
		_ = c.file.Close()
		_ = os.Remove(name)
		delete(s.captures, id)
	}
	for cursor, location := range s.cursors {
		if location.captureID == id {
			delete(s.cursors, cursor)
		}
	}
}

func (s *Store) Execute(ctx context.Context, reader adapter.CatalogMetadataReader, command protocol.Command) (*protocol.CatalogMetadataReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || command.CatalogMetadata == nil || !command.CatalogMetadata.Valid(command.Type) {
		return nil, ErrCursor
	}
	request := *command.CatalogMetadata
	if command.Type == "catalog.close" {
		for _, id := range request.CaptureIDs {
			s.remove(id)
		}
		return &protocol.CatalogMetadataReply{Closed: true, Collections: []protocol.CatalogMetadataCollection{}}, nil
	}
	if s.captures == nil {
		s.captures = make(map[string]*observation)
		s.cursors = make(map[string]continuation)
	}
	for id, c := range s.captures {
		if time.Now().After(c.expires) {
			s.remove(id)
		}
	}
	if request.Cursor != "" {
		location, ok := s.cursors[request.Cursor]
		c := s.captures[location.captureID]
		if !ok || c == nil || !reflect.DeepEqual(c.collection.Selector, request.Selectors[0]) {
			return nil, ErrCursor
		}
		page, err := s.page(ctx, c, location.group, request.PageSize)
		return &protocol.CatalogMetadataReply{Collections: []protocol.CatalogMetadataCollection{page}}, err
	}
	if len(s.captures)+len(request.Selectors) > MaxCaptures {
		return nil, errors.New("Close previous metadata observations before loading more objects.")
	}
	reply := &protocol.CatalogMetadataReply{Collections: []protocol.CatalogMetadataCollection{}}
	created := []string{}
	complete := false
	defer func() {
		if !complete {
			for _, id := range created {
				s.remove(id)
			}
		}
	}()
	for _, selector := range request.Selectors {
		if err := ctx.Err(); err != nil {
			for _, id := range created {
				s.remove(id)
			}
			return nil, err
		}
		file, err := os.CreateTemp("", "dbeer-metadata-*")
		if err != nil {
			for _, id := range created {
				s.remove(id)
			}
			return nil, errors.New("Private metadata storage is unavailable.")
		}
		if err = file.Chmod(0600); err != nil {
			name := file.Name()
			file.Close()
			os.Remove(name)
			return nil, errors.New("Private metadata storage is unavailable.")
		}
		id, err := token()
		if err != nil {
			name := file.Name()
			file.Close()
			os.Remove(name)
			for _, id := range created {
				s.remove(id)
			}
			return nil, err
		}
		c := &observation{file: file, expires: time.Now().Add(Lifetime), collection: protocol.CatalogMetadataCollection{Selector: selector, CaptureID: id, ObservedAt: time.Now().UTC().Format(time.RFC3339Nano), Consistency: "bestEffort", State: "complete", Columns: []protocol.Column{}, Rows: [][]*string{}}}
		remaining := int64(MaxBytes)
		for _, previous := range s.captures {
			remaining -= previous.bytes
		}
		sink := &captureSink{ctx: ctx, observation: c, quota: remaining, foreignKey: selector.Kind == "foreignKeys"}
		internal := protocol.Command{Type: "catalog", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, Catalog: &selector}
		response, consistency := reader.ReadCatalogMetadata(ctx, internal, sink)
		_ = sink.flush()
		c.collection.Consistency = consistency
		if response.Type == "error" {
			c.collection.State, c.collection.Issue = "unavailable", "Metadata is unavailable or access was denied."
			c.offsets = nil
		} else if response.MetadataStale {
			c.collection.State, c.collection.Issue = "stale", response.DisplayNotice
			c.offsets = nil
		} else if response.DisplayNotice != "" {
			c.collection.State, c.collection.Issue = "partial", response.DisplayNotice
		}
		if selector.Kind == "referencingTables" && c.collection.State != "unavailable" && c.collection.State != "stale" {
			if response.MetadataTarget == nil || !response.MetadataTarget.Valid() {
				c.collection.State, c.collection.Issue = "unavailable", "The canonical target identity is unavailable. Refresh explicitly."
				c.offsets = nil
			} else {
				c.collection.Target = response.MetadataTarget
			}
		}
		if err := ctx.Err(); err != nil {
			name := file.Name()
			file.Close()
			os.Remove(name)
			for _, id := range created {
				s.remove(id)
			}
			return nil, err
		}
		if response.Type == "error" && !response.Connected {
			name := file.Name()
			file.Close()
			os.Remove(name)
			return nil, &ReadError{Response: response}
		}
		s.captures[id] = c
		created = append(created, id)
		c.timer = time.AfterFunc(Lifetime, func() { s.mu.Lock(); defer s.mu.Unlock(); s.remove(id) })
		page, err := s.page(ctx, c, 0, request.PageSize)
		if err != nil {
			for _, id := range created {
				s.remove(id)
			}
			return nil, err
		}
		reply.Collections = append(reply.Collections, page)
	}
	complete = true
	return reply, nil
}

func (s *Store) page(ctx context.Context, c *observation, start, size int) (protocol.CatalogMetadataCollection, error) {
	page := c.collection
	page.Rows = [][]*string{}
	page.NextCursor = ""
	if size == 0 {
		size = protocol.CatalogMetadataPageRows
	}
	bytes := 0
	index := start
	for index < len(c.offsets) {
		if err := ctx.Err(); err != nil {
			return page, err
		}
		if _, err := c.file.Seek(c.offsets[index], io.SeekStart); err != nil {
			return page, ErrCursor
		}
		var rows [][]*string
		if err := json.NewDecoder(io.LimitReader(c.file, maxGroupBytes+1)).Decode(&rows); err != nil {
			return page, ErrCursor
		}
		encoded, _ := json.Marshal(rows)
		if len(page.Rows) > 0 && (len(page.Rows)+len(rows) > size || bytes+len(encoded) > maxGroupBytes) {
			break
		}
		page.Rows = append(page.Rows, rows...)
		bytes += len(encoded)
		index++
	}
	if index < len(c.offsets) {
		cursor := c.cursors[index]
		if cursor == "" {
			var err error
			cursor, err = token()
			if err != nil {
				return page, err
			}
			if c.cursors == nil {
				c.cursors = make(map[int]string)
			}
			c.cursors[index] = cursor
			s.cursors[cursor] = continuation{captureID: c.collection.CaptureID, group: index}
		}
		page.NextCursor = cursor
	}
	return page, nil
}

type captureSink struct {
	ctx         context.Context
	observation *observation
	quota       int64
	foreignKey  bool
	group       [][]*string
	groupKey    string
	groupBytes  int
	rows        int
	limited     bool
}

func (s *captureSink) Begin(_ int, columns []protocol.Column) error {
	if len(columns) > 64 {
		s.limit("Metadata column limit reached.")
		return nil
	}
	s.observation.collection.Columns = append([]protocol.Column{}, columns...)
	return s.ctx.Err()
}
func (s *captureSink) limit(reason string) {
	s.limited = true
	s.group = nil
	s.groupBytes = 0
	s.observation.collection.State = "partial"
	s.observation.collection.Issue = reason
}
func (s *captureSink) Row(_ int, row []*string) error {
	if err := s.ctx.Err(); err != nil {
		return err
	}
	if s.limited {
		return nil
	}
	if len(row) != len(s.observation.collection.Columns) {
		s.limit("Invalid metadata row. Refresh explicitly.")
		return nil
	}
	key := ""
	if s.foreignKey {
		if len(row) != 6 || row[0] == nil || row[1] == nil || row[2] == nil || row[3] == nil || row[4] == nil || row[5] == nil {
			s.limit("Incomplete foreign-key metadata. Refresh explicitly.")
			return nil
		}
		encoded, _ := json.Marshal(row[:3])
		key = string(encoded)
		if len(s.group) > 0 && key != s.groupKey {
			if err := s.flush(); err != nil {
				return err
			}
		}
		if s.limited {
			return nil
		}
		if *row[5] != strconv.Itoa(len(s.group)+1) || len(s.group) >= 32 {
			s.limit("Foreign-key mapping exceeds the supported atomic group. Narrow the scope.")
			return nil
		}
	}
	owned := make([]*string, len(row))
	for i, v := range row {
		if v != nil {
			copy := strings.Clone(*v)
			owned[i] = &copy
		}
	}
	encoded, _ := json.Marshal(owned)
	if s.rows >= MaxRows || s.groupBytes+len(encoded) > maxGroupBytes {
		s.limit("Metadata capture limit reached. Narrow the scope.")
		return nil
	}
	s.group = append(s.group, owned)
	s.groupBytes += len(encoded)
	s.groupKey = key
	s.rows++
	if !s.foreignKey {
		return s.flush()
	}
	return nil
}
func (s *captureSink) flush() error {
	if len(s.group) == 0 || s.limited {
		return nil
	}
	encoded, err := json.Marshal(s.group)
	if err != nil {
		return err
	}
	if len(encoded) > maxGroupBytes {
		s.limit("Metadata group exceeds the page limit. Narrow the scope.")
		return nil
	}
	if s.observation.bytes+int64(len(encoded)+1) > s.quota {
		s.limit("Metadata storage quota reached. Narrow the scope.")
		return nil
	}
	offset, err := s.observation.file.Seek(0, io.SeekCurrent)
	if err != nil {
		return err
	}
	if _, err = s.observation.file.Write(append(encoded, '\n')); err != nil {
		s.limit("Metadata storage is unavailable. Refresh explicitly.")
		return err
	}
	s.observation.offsets = append(s.observation.offsets, offset)
	s.observation.bytes += int64(len(encoded) + 1)
	s.group = nil
	s.groupBytes = 0
	return nil
}
func (s *captureSink) End(_ int, _ protocol.ResultSet) error { return s.flush() }
