package mariadb

import (
	"errors"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type mariaDBStructureFactReader func(tableedit.Target, string, string, string, string) (*tableedit.Facts, error)

// Only the owning worker calls this consumer. The concrete native fact reader
// is supplied by the adapter; no protocol field or portable intent can supply it.
func (s *Session) readMariaDBStructure(target tableedit.Target, readFacts mariaDBStructureFactReader) (tableedit.Baseline, error) {
	reconcile := target.Reconcile
	target.Reconcile = false
	baseline := tableedit.Baseline{Engine: "mariadb", Target: target, Columns: []tableedit.ObservedColumn{}, Keys: []tableedit.Key{}, Indexes: []tableedit.Index{}, Limitations: []string{
		"MariaDB DDL implicitly commits and may lock, scan or rebuild native tables. Stop and Discard cannot undo acknowledged DDL; no automatic retry or reconnect is performed.",
		"Metadata is rechecked on the owning physical session. MariaDB does not provide a transactional DDL snapshot that closes concurrent DDL or proves a dropped-and-recreated table has the original identity.",
	}}
	context, err := s.mariaDBStructureContext(target)
	if err != nil {
		return baseline, err
	}
	baseline.Scope = tableedit.Fingerprint(context.Native)
	if strings.Contains(context.SQLMode, "NO_TABLE_OPTIONS") || strings.Contains(context.SQLMode, "NO_FIELD_OPTIONS") || strings.Contains(context.SQLMode, "NO_KEY_OPTIONS") {
		return baseline, errors.New("The current MariaDB SQL mode omits native properties from SHOW CREATE. Review and change that mode explicitly before structure editing.")
	}
	definition, err := s.work.client.Execute("SHOW CREATE TABLE " + QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(target.Table))
	if err != nil {
		var native *wire.MyError
		if !errors.As(err, &native) || native.Code != 1146 || !target.Create {
			return baseline, err
		}
		// An ERR packet carries no transaction flags. Refresh them with COM_PING
		// after the positively recognized missing-object result, before proceeding.
		if err = s.work.client.Ping(); err != nil {
			return baseline, err
		}
		s.updateTransaction()
		if s.TransactionStatus() != "idle" {
			return baseline, tableedit.ErrUnsupported
		}
		baseline.Facts = newMariaDBStructureFacts(context.SchemaCharset, context.SchemaCollation)
		baseline.Facts.ServerVersion = context.ServerVersion
		baseline.Facts.EngineContext = []sc.Option{{Name: "sqlMode", Value: context.SQLMode}}
		baseline.Facts.Table.Ref = sc.Ref{Kind: "table", Schema: target.Schema, Name: target.Table}
		mariaDBBindStructureControls(baseline.Facts, context.Native)
		tableedit.Summarize(&baseline)
		baseline.Fingerprint = tableedit.Fingerprint([]any{context.Native, target, baseline.Facts})
		return baseline, nil
	}
	if definition.RowNumber() != 1 || definition.ColumnNumber() < 2 {
		definition.Close()
		return baseline, tableedit.ErrUnsupported
	}
	nativeDefinition, err := definition.GetString(0, 1)
	baseline.NativeDefinition = strings.Clone(nativeDefinition)
	definition.Close()
	if err != nil || !strings.HasPrefix(baseline.NativeDefinition, "CREATE TABLE ") || len(baseline.NativeDefinition) > tableedit.MaxSQLBytes {
		return baseline, errors.New("Temporary tables and views require their original physical SQL owner and cannot be edited by the dedicated structure workflow.")
	}
	if target.Create && !reconcile {
		return baseline, errors.New("The native target already exists. Load and reconcile it before preparing changes.")
	}
	baseline.Target.Create = false
	object, err := s.work.client.Execute(`SELECT TABLE_TYPE,ENGINE,CREATE_OPTIONS,TABLE_COLLATION,TABLE_COMMENT FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 2`, target.Schema, target.Table)
	if err != nil {
		return baseline, err
	}
	if object.RowNumber() != 1 {
		object.Close()
		return baseline, tableedit.ErrUnsupported
	}
	props := make([]string, 5)
	for i := range props {
		v, e := object.GetString(0, i)
		if e != nil {
			object.Close()
			return baseline, tableedit.ErrUnsupported
		}
		props[i] = strings.Clone(v)
	}
	object.Close()
	if props[0] != "BASE TABLE" && props[0] != "SYSTEM VERSIONED" || props[1] != "InnoDB" && props[1] != "MyISAM" && props[1] != "Aria" {
		return baseline, errors.New("Structure editing requires a native permanent InnoDB, MyISAM or Aria table; other storage models need a separate supported operation proof.")
	}
	columns, err := s.work.client.Execute(`SELECT COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION LIMIT 129`, target.Schema, target.Table)
	if err != nil {
		return baseline, err
	}
	if columns.RowNumber() == 0 || columns.RowNumber() > tableedit.MaxColumns {
		columns.Close()
		return baseline, tableedit.ErrUnsupported
	}
	for i := 0; i < columns.RowNumber(); i++ {
		name, e1 := columns.GetString(i, 0)
		native, e2 := columns.GetString(i, 1)
		nullable, e3 := columns.GetString(i, 2)
		isNull, e4 := columns.IsNull(i, 3)
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil || !tableedit.Identifier(name) || nullable != "YES" && nullable != "NO" {
			columns.Close()
			return baseline, tableedit.ErrUnsupported
		}
		column := tableedit.ObservedColumn{Name: strings.Clone(name), NativeType: strings.Clone(native), Nullable: nullable == "YES"}
		if !isNull {
			v, e := columns.GetString(i, 3)
			if e != nil {
				columns.Close()
				return baseline, e
			}
			owned := strings.Clone(v)
			column.DefaultExpression = &owned
		}
		baseline.Columns = append(baseline.Columns, column)
	}
	columns.Close()
	if readFacts == nil {
		return baseline, tableedit.ErrUnsupported
	}
	baseline.Facts, err = readFacts(baseline.Target, props[1], props[3], props[2], props[4])
	if err != nil {
		return baseline, err
	}
	if baseline.Facts == nil {
		return baseline, tableedit.ErrUnsupported
	}
	if err = mariaDBObservedDefaults(&baseline); err != nil {
		return baseline, err
	}
	baseline.Facts.ServerVersion = context.ServerVersion
	mariaDBBindStructureControls(baseline.Facts, context.Native)
	baseline.Guard = tableedit.Fingerprint(props[:4])
	partitions, err := s.work.client.Execute(`SELECT COUNT(*) FROM information_schema.PARTITIONS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND PARTITION_NAME IS NOT NULL`, target.Schema, target.Table)
	if err != nil {
		return baseline, err
	}
	count, e := partitions.GetUint(0, 0)
	valid := partitions.RowNumber() == 1 && e == nil
	partitions.Close()
	if !valid {
		return baseline, tableedit.ErrUnsupported
	}
	kinds := []string{}
	if count > 0 {
		kinds = append(kinds, "mariaDBPartitions")
	}
	if props[1] == "MyISAM" {
		kinds = append(kinds, "mariaDBMyISAM")
	}
	if props[1] == "Aria" {
		kinds = append(kinds, "mariaDBAria")
	}
	if props[0] == "SYSTEM VERSIONED" {
		kinds = append(kinds, "mariaDBSystemVersioned")
	}
	if len(kinds) > 0 {
		reasons := map[string]string{}
		for _, operation := range tableedit.AdvancedOperationKinds {
			reasons[operation] = "This MariaDB operation requires a complete native preservation proof for the selected storage/partition/history model."
		}
		baseline.Advanced = tableedit.NewAdvancedSupport(kinds, "operation", 1, props[1] != "InnoDB", reasons)
		kind := "table"
		if count > 0 {
			kind = "partitionedTable"
		}
		baseline.Advanced.Relations = []tableedit.AdvancedRelationFact{{Target: baseline.Target, Kind: kind, Persistence: "permanent", StorageEngine: props[1], Parents: []tableedit.Target{}, Policies: []tableedit.AdvancedPolicyFact{}}}
	}
	tableedit.Summarize(&baseline)
	baseline.Fingerprint = tableedit.Fingerprint([]any{context.Native, props, baseline.NativeDefinition, baseline.Columns, baseline.Facts, baseline.Advanced})
	if !tableedit.ValidBaseline(baseline) {
		return baseline, tableedit.ErrUnsupported
	}
	return baseline, nil
}

func mariaDBBindStructureControls(facts *tableedit.Facts, native []string) {
	for i, key := range []string{"autocommit", "foreignKeyChecks", "systemVersioningAlterHistory", "innodbStrictMode"} {
		facts.EngineContext = append(facts.EngineContext, sc.Option{Name: key, Value: native[19+i]})
	}
	sortMariaOptions(facts.EngineContext)
}
