package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"testing"
)

type tuningAdvancedFake struct {
	*tuningFake
	engine string
}

func (f *tuningAdvancedFake) ExplainSupport() protocol.ExplainSupport {
	version := "17.10"
	if f.engine == "mysql" {
		version = "8.4.13"
	}
	return adapter.ExplainSupport(f.engine, version)
}
func TestTuningRejectsEveryAdvancedKindBeforeQueries(t *testing.T) {
	for _, kind := range []string{"rowSecurity", "inheritanceParent", "inheritanceChild", "partitionParent", "partitionMember", "typed", "unlogged", "myISAM", "mySQLPartitions", "futureUnknownKind"} {
		t.Run(kind, func(t *testing.T) {
			b := tuningBaseline()
			engine := "postgresql"
			if kind == "myISAM" || kind == "mySQLPartitions" {
				engine = "mysql"
				b.Engine = engine
			}
			b.Advanced = &tableedit.AdvancedKindSupport{Kinds: []string{kind}}
			q, ok := parseTuningQuery(engine, tuningRequest("SELECT id FROM public.items WHERE id = 1 OR id = 2"), b.Target)
			if !ok || tuningCatalogSafe(b, q) {
				t.Fatal("any nonnil advanced proof must be outside tuning's ordinary validator")
			}
			r := protocol.TuningInspectRequest{Version: 1, Source: tuningRequest("SELECT id FROM public.items WHERE id = 1 OR id = 2"), Capture: tuningCapture(), Target: b.Target}
			f := &tuningAdvancedFake{tuningFake: &tuningFake{status: "idle", metadata: b}, engine: engine}
			r.Capture.Support = f.ExplainSupport()
			out := tuningInspection(r, b)
			if len(out.Indexes) != 0 || len(out.Variants) != 0 {
				t.Fatal("advanced metadata produced ordinary tuning advice")
			}
			o := &owner{id: "owner"}
			response := o.runTuning(context.Background(), f, protocol.Command{Type: "tuning.inspect", TuningInspect: &r}, engine)
			if response.Type != "error" || len(f.calls) != 0 || response.TuningInspection != nil {
				t.Fatal("advanced inspection dispatched query work")
			}
			v := validationRequest()
			response = o.runTuning(context.Background(), f, protocol.Command{Type: "tuning.validate", TuningValidation: &v}, engine)
			if response.Type != "error" || len(f.calls) != 0 || response.TuningValidation != nil {
				t.Fatal("advanced validation dispatched SELECT or policy/function work")
			}
		})
	}
}
