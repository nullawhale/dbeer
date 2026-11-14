package mariadb

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func (s *Session) requireNativeMetadataEncoding() error {
	result, err := s.work.client.Execute("SELECT @@character_set_client,@@character_set_connection,@@character_set_results")
	if err != nil {
		return err
	}
	defer result.Close()
	if result.RowNumber() != 1 {
		return errors.New("Native metadata encoding is unavailable.")
	}
	for i := 0; i < 3; i++ {
		value, err := result.GetString(0, i)
		if err != nil || value != "utf8mb4" {
			return errors.New("Native MariaDB metadata requires an already active utf8mb4 client, connection and result encoding; no encoding is changed implicitly.")
		}
	}
	return nil
}

func (s *Session) catalogBrowse(ctx context.Context, c protocol.Command, sinks ...adapter.ResultSink) protocol.Response {
	r := *c.Catalog
	if r.Cursor != "" {
		return s.featureUnavailable(c)
	}
	var sourceSQL string
	response := s.executeWith(ctx, c, func(collector *collector, result *wire.Result) error {
		if err := s.requireNativeMetadataEncoding(); err != nil {
			return err
		}
		definition, err := s.work.client.Execute("SHOW CREATE TABLE " + QuoteIdentifier(r.Schema) + "." + QuoteIdentifier(r.Object))
		if err != nil {
			return err
		}
		if definition.RowNumber() != 1 || len(definition.Fields) < 2 {
			definition.Close()
			return &adapter.ConnectionError{Category: "validation", Message: "The exact native browse target is unavailable."}
		}
		ddl, e := definition.GetString(0, 1)
		isView := strings.EqualFold(string(definition.Fields[1].Name), "Create View")
		permanent := e == nil && (strings.HasPrefix(ddl, "CREATE TABLE ") || isView)
		definition.Close()
		if !permanent {
			return &adapter.ConnectionError{Category: "validation", Message: "Temporary tables belong to their original physical SQL tab. Query them there instead of opening them through the catalog table browser."}
		}
		target, err := s.work.client.Execute(`SELECT TABLE_NAME,TABLE_TYPE FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 1`, r.Schema, r.Object)
		if err != nil {
			return err
		}
		valid := target.RowNumber() == 1
		nativeKind := ""
		if valid {
			kind, e := target.GetString(0, 1)
			nativeKind = strings.Clone(kind)
			valid = e == nil && (kind == "BASE TABLE" || kind == "SYSTEM VERSIONED" || kind == "VIEW") && (kind == "VIEW") == isView
		}
		target.Close()
		if !valid {
			return errors.New("The exact browsed table or view is unavailable.")
		}
		metadata, err := s.work.client.Execute(`SELECT COLUMN_NAME,DATA_TYPE,CHARACTER_SET_NAME,COLUMN_TYPE,COALESCE(GENERATION_EXPRESSION,'') FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION LIMIT 1025`, r.Schema, r.Object)
		if err != nil {
			return err
		}
		actual := map[string]string{}
		columnOrder := []string{}
		periodColumns := []MariaDBPeriodColumn{}
		for i := 0; i < metadata.RowNumber(); i++ {
			name, e := metadata.GetString(i, 0)
			if e != nil {
				metadata.Close()
				return e
			}
			kind, e := metadata.GetString(i, 1)
			if e != nil {
				metadata.Close()
				return e
			}
			charset, _ := metadata.GetString(i, 2)
			if (kind == "enum" || kind == "set") && (charset == "" || charset == "binary") {
				kind += "Binary"
			}
			native, _ := metadata.GetString(i, 3)
			generated, _ := metadata.GetString(i, 4)
			periodColumns = append(periodColumns, MariaDBPeriodColumn{Name: strings.Clone(name), NativeType: strings.Clone(native), DataType: strings.TrimSuffix(kind, "Binary"), Generated: strings.Clone(generated)})
			name = strings.Clone(name)
			actual[name] = strings.Clone(kind)
			columnOrder = append(columnOrder, name)
		}
		metadata.Close()
		if len(actual) == 0 || len(actual) > 1024 {
			return errors.New("Complete bounded browse columns are unavailable.")
		}
		keys, err := s.work.client.Execute(`SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION`, r.Schema, r.Object)
		if err != nil {
			return err
		}
		primary := []string{}
		for i := 0; i < keys.RowNumber(); i++ {
			name, e := keys.GetString(i, 0)
			if e != nil {
				keys.Close()
				return e
			}
			primary = append(primary, strings.Clone(name))
		}
		keys.Close()
		periods, err := MariaDBSystemPeriods(s.work.client.Execute, r.Schema, r.Object, nativeKind, periodColumns)
		if err != nil {
			return err
		}
		plan, err := buildMariaDBBrowsePlan(r, actual, primary, columnOrder, periods)
		if err != nil {
			return &adapter.ConnectionError{Category: "validation", Message: err.Error()}
		}
		sourceSQL = plan.sourceSQL
		if r.Kind == "select" {
			return collectCatalogRows(collector, []string{"sql", "name"}, [][]*string{{text(sourceSQL), text(QuoteIdentifier(r.Schema) + "." + QuoteIdentifier(r.Object))}})
		}
		collector.hiddenStorageFields = len(plan.storage)
		if err := s.executeResults(plan.statement, collector, result); err != nil {
			return err
		}
		collector.response.Source = mariadbReadOnlySource(mariadbSourceUnavailable)
		collector.sourceReadCompleted = true
		if len(primary) == 0 {
			collector.response.DisplayNotice = "This object has no primary key; concurrent changes can repeat or omit rows between offset pages."
		}
		return nil
	}, sinks...)
	if response.Type == "query.result" && r.Kind == "browse" {
		response = response.WithReadSQL(sourceSQL)
	}
	return response
}

type mariaDBBrowsePlan struct {
	statement, sourceSQL string
	storage              []string
}

func buildMariaDBBrowsePlan(request protocol.CatalogRequest, actual map[string]string, primary, columnOrder []string, periods []MariaDBPeriodColumn) (mariaDBBrowsePlan, error) {
	var plan mariaDBBrowsePlan
	if len(actual) == 0 || len(actual) != len(columnOrder) {
		return plan, errors.New("Complete native browse columns are unavailable.")
	}
	visible := []string{}
	seenColumns := map[string]bool{}
	for _, name := range columnOrder {
		kind, ok := actual[name]
		if !ok || seenColumns[name] {
			return plan, errors.New("Native browse column order changed.")
		}
		seenColumns[name] = true
		expression := MariaDBStableProjection(name, kind)
		if expression != QuoteIdentifier(name) {
			expression += " AS " + QuoteIdentifier(name)
		}
		visible = append(visible, expression)
	}
	order := []string{}
	seen := map[string]bool{}
	for _, sort := range request.Sort {
		if _, ok := actual[sort.Column]; !ok || seen[sort.Column] || sort.Direction != "asc" && sort.Direction != "desc" {
			return plan, errors.New("The requested native sort column is unavailable or repeated.")
		}
		seen[sort.Column] = true
		order = append(order, QuoteIdentifier(sort.Column)+" "+strings.ToUpper(sort.Direction))
	}
	for _, name := range primary {
		if _, ok := actual[name]; !ok {
			implicit := false
			for _, period := range periods {
				if period.Implicit && strings.EqualFold(period.Name, name) {
					name = period.Name
					implicit = true
					break
				}
			}
			if !implicit {
				return plan, errors.New("The exact native primary-key column disappeared.")
			}
		}
		if !seen[name] {
			order = append(order, QuoteIdentifier(name))
			seen[name] = true
		}
	}
	storageKinds := map[string]string{}
	for name, kind := range actual {
		storageKinds[name] = kind
	}
	for _, period := range periods {
		if period.Implicit {
			storageKinds[period.Name] = period.DataType
		}
	}
	plan.storage = MariaDBStorageColumns(storageKinds)
	storage := MariaDBStorageProjections(plan.storage, storageKinds)
	if len(storage) != len(plan.storage) {
		return plan, errors.New("Native storage projections are unavailable.")
	}
	predicate, err := mariaDBBrowsePredicate(request, actual)
	if err != nil {
		return plan, err
	}
	statement := func(projection []string) string {
		sql := "SELECT " + strings.Join(projection, ", ") + " FROM " + QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Object)
		if predicate != "" {
			sql += " WHERE " + predicate
		}
		if len(order) > 0 {
			sql += " ORDER BY " + strings.Join(order, ", ")
		}
		return sql + " LIMIT 200 OFFSET " + strconv.Itoa(request.Page*200)
	}
	plan.sourceSQL = statement(visible)
	plan.statement = statement(append(append([]string{}, visible...), storage...))
	return plan, nil
}
