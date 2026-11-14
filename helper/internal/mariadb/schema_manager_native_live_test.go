package mariadb_test

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/schemajob"
	"dbeer/helper/internal/syncplan"
)

type mariaDBSchemaJobOwner struct {
	adapter.Session
	readonly, closed atomic.Bool
}

func (s *mariaDBSchemaJobOwner) SetReadOnly(ctx context.Context, v bool) error {
	e := s.Session.(adapter.ReadOnlySession).SetReadOnly(ctx, v)
	if e == nil {
		s.readonly.Store(v)
	}
	return e
}
func (s *mariaDBSchemaJobOwner) Close() { s.closed.Store(true); s.Session.Close() }
func (s *mariaDBSchemaJobOwner) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	return s.Session.(adapter.SchemaReader).ReadSchema(ctx, spec, sink)
}

func TestMariaDBSchemaNativeNormalJobDefinitionSyncAndOwnerLifetime(t *testing.T) {
	settings := tuningFlowSettings(t)
	owner, e := mariadb.Open(context.Background(), settings)
	if e != nil {
		t.Fatal("schema fixture unavailable")
	}
	defer owner.Close()
	run := func(sql string) protocol.Response {
		t.Helper()
		r := owner.Execute(context.Background(), protocol.Command{SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("schema fixture failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	src, dst := fmt.Sprintf("g1_schema_src_%d", time.Now().UnixNano()), fmt.Sprintf("g1_schema_dst_%d", time.Now().UnixNano())
	for _, name := range []string{src, dst} {
		run("CREATE DATABASE " + mariadb.QuoteIdentifier(name) + " CHARACTER SET utf8mb4")
		defer run("DROP DATABASE IF EXISTS " + mariadb.QuoteIdentifier(name))
	}
	run("CREATE TABLE " + mariadb.QuoteIdentifier(src) + ".`t`(id BIGINT NOT NULL,n DECIMAL(65,38),v VARCHAR(20) DEFAULT 'NULL',PRIMARY KEY(id),KEY kept(v(3) DESC) IGNORED COMMENT 'retained') ENGINE=InnoDB")
	var mu sync.Mutex
	owners := []*mariaDBSchemaJobOwner{}
	identities := map[string]bool{}
	open := func(ctx context.Context, c protocol.Connection) (adapter.Session, error) {
		s, e := mariadb.Open(ctx, c)
		if e != nil {
			return nil, e
		}
		r := s.Execute(ctx, protocol.Command{SQL: "SELECT CONNECTION_ID()"})
		if r.Type != "query.result" || len(r.Rows) != 1 || r.Rows[0][0] == nil {
			s.Close()
			t.Error("schema owner identity unavailable")
			return nil, fmt.Errorf("identity unavailable")
		}
		wrapped := &mariaDBSchemaJobOwner{Session: s}
		mu.Lock()
		defer mu.Unlock()
		if identities[*r.Rows[0][0]] {
			t.Error("schema owners shared a physical connection")
		}
		identities[*r.Rows[0][0]] = true
		owners = append(owners, wrapped)
		return wrapped, nil
	}
	jobs, e := schemajob.New(open, schemajob.Options{Root: t.TempDir(), RenderDefinition: mariadb.RenderSchemaDefinition, RenderPlan: func(ctx context.Context, r sc.Report) (syncplan.Plan, error) {
		return syncplan.Schema(ctx, r, mariadb.RenderSynchronizationSchema)
	}})
	if e != nil {
		t.Fatal("schema Manager unavailable")
	}
	defer jobs.Close()
	req := &protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Connection: settings}, Target: &protocol.SchemaSide{Connection: settings}, Mappings: &sc.Mappings{Schemas: []sc.NamePair{{Source: src, Target: dst}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}
	started := jobs.Handle(protocol.Command{Type: "schema.start", SchemaComparison: req})
	if started.SchemaComparison == nil {
		t.Fatal("normal schema job refused native engine")
	}
	id := started.SchemaComparison.JobID
	wait := func(kind string) *protocol.SchemaComparisonResponse {
		t.Helper()
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			r := jobs.Handle(protocol.Command{Type: kind, SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
			if r.SchemaComparison != nil {
				if r.SchemaComparison.State == "completed" {
					return r.SchemaComparison
				}
				if r.SchemaComparison.State == "failed" {
					t.Fatalf("schema job failed: %s", r.SchemaComparison.Code)
				}
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("schema job did not complete")
		return nil
	}
	status := wait("schema.status")
	if status.Summary == nil || status.Summary.Engine != "mariadb" || len(status.Summary.ModelDigest) != 64 {
		t.Fatal("native schema model identity missing")
	}
	mu.Lock()
	if len(owners) != 2 {
		t.Error("schema comparison did not own two sessions")
	}
	for _, s := range owners {
		if !s.readonly.Load() || !s.closed.Load() {
			t.Error("schema service owner did not close after readonly capture")
		}
	}
	mu.Unlock()
	planReq := func(digest string) protocol.Response {
		return jobs.Handle(protocol.Command{Type: "schema.plan", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ModelDigest: digest}})
	}
	if r := planReq(strings.Repeat("0", 64)); r.Type != "error" {
		t.Fatal("stale model digest gained plan authority")
	}
	r := planReq(status.Summary.ModelDigest)
	if r.SchemaComparison == nil || r.SchemaComparison.Plan == nil || r.SchemaComparison.Plan.Engine != "mariadb" || r.SchemaComparison.Plan.Validate() != nil {
		t.Fatal("normal schema Manager lost native renderer registry")
	}
	automatic := false
	for _, step := range r.SchemaComparison.Plan.Steps {
		if !step.Manual && strings.Contains(step.SQL, "CREATE TABLE") {
			automatic = true
		}
	}
	if !automatic {
		t.Fatal("represented ordinary table creation became manual")
	}
	// The generated draft is retained historical metadata and never executes itself.
	if rows := run("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='" + dst + "'").Rows; len(rows) != 1 || rows[0][0] == nil || *rows[0][0] != "0" {
		t.Fatal("schema comparison or draft generation executed DDL")
	}
	jobs.Handle(protocol.Command{Type: "schema.close", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
	if r := planReq(status.Summary.ModelDigest); r.Type != "error" {
		t.Fatal("retired schema owner returned a draft")
	}
	// A bundle has one readonly owner; unmodeled database options stay explicitly incomplete.
	b := jobs.Handle(protocol.Command{Type: "schema.bundle.start", SchemaComparison: &protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Connection: settings}, Schemas: []string{src}}})
	if b.SchemaComparison == nil {
		t.Fatal("native bundle job refused")
	}
	id = b.SchemaComparison.JobID
	bs := wait("schema.bundle.status")
	if bs.BundleSummary == nil || bs.BundleSummary.Engine != "mariadb" {
		t.Fatal("native bundle identity missing")
	}
	export := jobs.Handle(protocol.Command{Type: "schema.bundle.export", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ValueRef: "manifest", MaxBytes: 4096}})
	if export.SchemaComparison == nil || export.SchemaComparison.Export == nil {
		t.Fatal("native bundle manifest unavailable")
	}
	jobs.Close()
	mu.Lock()
	defer mu.Unlock()
	if len(owners) != 3 {
		t.Error("bundle did not use exactly one new owner")
	}
	for _, s := range owners {
		if !s.readonly.Load() || !s.closed.Load() {
			t.Error("schema service leaked writable or live owner")
		}
	}
}
