package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"strings"
	"testing"
)

func physicalMySQLProofFixture() myPhysicalEvidence {
	b := mysqlDestructiveBaseline(tableedit.DataType{Kind: "integer"})
	b.Scope = "owned-session"
	b.Facts.Table.Kind = sc.Unknown[string]("tableEngineOrOptions")
	b.Facts.Table.Storage = sc.Known("InnoDB")
	b.Facts.Table.Charset = sc.Known("utf8mb4")
	b.Facts.Table.Collation = sc.Known(sc.Ref{Kind: "collation", Name: "utf8mb4_bin"})
	b.Facts.Table.Options = sc.Complete([]sc.Option{{Name: "createOptions", Value: "partitioned"}, {Name: "comment", Value: "retained"}})
	b.NativeDefinition = "CREATE TABLE `fixture`.`table` (`id` int DEFAULT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='retained' ROW_FORMAT=DYNAMIC /*!50100 PARTITION BY RANGE (`id`) (PARTITION p0 VALUES LESS THAN (10) ENGINE = InnoDB, PARTITION p1 VALUES LESS THAN MAXVALUE ENGINE = InnoDB) */"
	return myPhysicalEvidence{Baseline: b, Engine: "InnoDB", Partitions: [][]*string{physicalMySQLRow("p0", "1", "RANGE", "`id`", "10"), physicalMySQLRow("p1", "2", "RANGE", "`id`", "MAXVALUE")}}
}
func physicalMySQLRow(values ...string) []*string {
	out := make([]*string, 11)
	for i, v := range values {
		v := v
		out[i] = &v
	}
	return out
}
func clonePhysicalMySQLFixture(a myPhysicalEvidence) myPhysicalEvidence {
	b := a
	raw, _ := json.Marshal(a.Baseline.Facts)
	var facts tableedit.Facts
	_ = json.Unmarshal(raw, &facts)
	b.Baseline.Facts = &facts
	raw, _ = json.Marshal(a.Partitions)
	_ = json.Unmarshal(raw, &b.Partitions)
	return b
}
func TestPhysicalMySQLPartitionPreservationRejectsEveryUnselectedPropertyMutation(t *testing.T) {
	a := physicalMySQLProofFixture()
	x := tableedit.PhysicalIntent{Kind: "truncatePartition", Partitions: []string{"p0"}, Algorithm: "INPLACE", Lock: "NONE"}
	if !myPhysicalExpected(a, clonePhysicalMySQLFixture(a), x) {
		t.Fatal("nonempty native options or MAXVALUE partition proof rejected")
	}
	mutations := map[string]func(*myPhysicalEvidence){
		"native-engine": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "ENGINE=InnoDB", "ENGINE=MyISAM", 1)
		},
		"native-charset": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "CHARSET=utf8mb4", "CHARSET=latin1", 1)
		},
		"native-collation": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "COLLATE=utf8mb4_bin", "COLLATE=utf8mb4_0900_ai_ci", 1)
		},
		"native-comment": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "COMMENT='retained'", "COMMENT='changed'", 1)
		},
		"native-row-format": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "ROW_FORMAT=DYNAMIC", "ROW_FORMAT=COMPACT", 1)
		},
		"native-unknown-option": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "ROW_FORMAT=DYNAMIC", "ROW_FORMAT=DYNAMIC STATS_PERSISTENT=0", 1)
		},
		"partition-unknown-option": func(b *myPhysicalEvidence) {
			b.Baseline.NativeDefinition = strings.Replace(b.Baseline.NativeDefinition, "p1 VALUES LESS THAN MAXVALUE ENGINE = InnoDB", "p1 VALUES LESS THAN MAXVALUE ENGINE = InnoDB MAX_ROWS = 1", 1)
		},
		"storage-fact": func(b *myPhysicalEvidence) { b.Baseline.Facts.Table.Storage = sc.Known("MyISAM") },
		"charset-fact": func(b *myPhysicalEvidence) { b.Baseline.Facts.Table.Charset = sc.Known("latin1") },
		"collation-fact": func(b *myPhysicalEvidence) {
			b.Baseline.Facts.Table.Collation = sc.Known(sc.Ref{Kind: "collation", Name: "other"})
		},
		"options-fact": func(b *myPhysicalEvidence) {
			b.Baseline.Facts.Table.Options.Items = append(b.Baseline.Facts.Table.Options.Items, sc.Option{Name: "unknown", Value: "changed"})
		},
		"type-fact": func(b *myPhysicalEvidence) {
			b.Baseline.Facts.Types = append(b.Baseline.Facts.Types, sc.TypeDefinition{Ref: sc.Ref{Kind: "type", Name: "changed"}})
		},
		"kind-fact": func(b *myPhysicalEvidence) { b.Baseline.Facts.Table.Kind = sc.Unknown[string]("unrecognized") },
		"session-context": func(b *myPhysicalEvidence) {
			b.Baseline.Facts.EngineContext = append(b.Baseline.Facts.EngineContext, sc.Option{Name: "unselected", Value: "changed"})
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			b := clonePhysicalMySQLFixture(a)
			mutate(&b)
			if myPhysicalExpected(a, b, x) {
				t.Fatal("unselected property mutation was accepted")
			}
		})
	}
}
func TestPhysicalMySQLHashInitialPartitionCountBoundary(t *testing.T) {
	b := mysqlDestructiveBaseline(tableedit.DataType{Kind: "integer"})
	b.Facts.ServerVersion = 80400
	b.Facts.Table.Storage = sc.Known("InnoDB")
	b.Columns = []tableedit.ObservedColumn{{Name: b.Facts.Table.Columns.Items[0].Ref.Name}}
	for _, method := range []string{"hash", "key"} {
		for _, count := range []int{128, 129} {
			d := tableedit.PhysicalDraft{Version: 1, Target: b.Target, Intent: tableedit.PhysicalIntent{Kind: "partitionTable", Method: method, Columns: []string{b.Columns[0].Name}, Count: count, Algorithm: "COPY", Lock: "SHARED"}}
			p, e := (&Session{}).myPhysicalPlan(context.Background(), d, myPhysicalEvidence{Baseline: b, Engine: "InnoDB"})
			if count == 128 && (e != nil || len(p.SQL) != 1) {
				t.Fatal("inspectable partition count boundary rejected")
			}
			if count == 129 && (e == nil || len(p.SQL) > 0) {
				t.Fatal("uninspectable partition count reached SQL rendering")
			}
		}
	}
}
