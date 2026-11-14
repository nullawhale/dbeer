package session

import (
	"context"
	"slices"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type metricsExplainTestSession struct {
	*explainTestSession
	support protocol.ExplainSupport
}

func (s *metricsExplainTestSession) ExplainSupport() protocol.ExplainSupport { return s.support }
func TestExplainMetricsOwnerCapability(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql", "sqlite"} {
		t.Run(engine, func(t *testing.T) {
			physical := &metricsExplainTestSession{explainTestSession: &explainTestSession{testSession: blockingSession()}, support: adapter.ExplainSupport(engine, map[string]string{"postgresql": "17.10", "mysql": "8.4.13", "sqlite": "3.51.0"}[engine])}
			manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
			defer manager.Close()
			submit(t, manager, protocol.Command{Type: "connect", RequestID: "metrics-connect", Connection: &protocol.Connection{Database: "metrics"}})
			response := receive(t, manager)
			if response.Type != "connect.result" || slices.Contains(response.Capabilities, protocol.ExplainMetricsCapability) != (engine != "sqlite") {
				t.Fatal("owning session metrics capability")
			}
		})
	}
}
