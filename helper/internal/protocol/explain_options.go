package protocol

import "encoding/json"

// Exactly one engine owns the options. Absent fields retain the legacy defaults.
type ExplainOptions struct {
	PostgreSQL *PostgresExplainOptions `json:"postgresql,omitempty"`
	MySQL      *MySQLExplainOptions    `json:"mysql,omitempty"`
}
type PostgresExplainOptions struct {
	Buffers   *bool  `json:"buffers,omitempty"`
	WAL       *bool  `json:"wal,omitempty"`
	Settings  *bool  `json:"settings,omitempty"`
	Memory    *bool  `json:"memory,omitempty"`
	Serialize string `json:"serialize,omitempty"`
	Timing    *bool  `json:"timing,omitempty"`
}
type MySQLExplainOptions struct {
	Format string `json:"format"`
}

func (o ExplainOptions) Valid() bool {
	if (o.PostgreSQL == nil) == (o.MySQL == nil) {
		return false
	}
	if o.PostgreSQL != nil {
		return o.PostgreSQL.Serialize == "" || containsExplainString([]string{"none", "text", "binary"}, o.PostgreSQL.Serialize)
	}
	return containsExplainString([]string{"auto", "tree", "json"}, o.MySQL.Format)
}
func (o ExplainOptions) ForEngine(engine string) bool {
	return engine == "postgresql" && o.PostgreSQL != nil && o.MySQL == nil || engine == "mysql" && o.MySQL != nil && o.PostgreSQL == nil
}
func parseExplainOptions(raw json.RawMessage) (*ExplainOptions, bool) {
	fields, ok := changesObject(raw, "postgresql|mysql")
	if !ok || len(fields) != 1 {
		return nil, false
	}
	o := &ExplainOptions{}
	if v, exists := fields["postgresql"]; exists {
		f, ok := changesObject(v, "buffers|wal|settings|memory|serialize|timing")
		if !ok {
			return nil, false
		}
		pg := &PostgresExplainOptions{}
		for key, dest := range map[string]**bool{"buffers": &pg.Buffers, "wal": &pg.WAL, "settings": &pg.Settings, "memory": &pg.Memory, "timing": &pg.Timing} {
			if value, exists := f[key]; exists {
				var b *bool
				if json.Unmarshal(value, &b) != nil || b == nil {
					return nil, false
				}
				*dest = b
			}
		}
		if _, exists := f["serialize"]; exists && (!stringField(f, "serialize", &pg.Serialize) || pg.Serialize == "") {
			return nil, false
		}
		o.PostgreSQL = pg
	} else {
		f, ok := changesObject(fields["mysql"], "format", "format")
		if !ok {
			return nil, false
		}
		my := &MySQLExplainOptions{}
		if !stringField(f, "format", &my.Format) {
			return nil, false
		}
		o.MySQL = my
	}
	return o, o.Valid()
}

type ExplainOptionSupport struct {
	PostgreSQL *PostgresExplainOptionSupport `json:"postgresql,omitempty"`
	MySQL      *MySQLExplainOptionSupport    `json:"mysql,omitempty"`
}
type PostgresExplainOptionSupport struct {
	Plan    []string `json:"plan"`
	Analyze []string `json:"analyze"`
}
type MySQLExplainOptionSupport struct {
	Plan                        []string `json:"plan"`
	Analyze                     []string `json:"analyze"`
	JSONAnalyzeRequiresVersion2 bool     `json:"jsonAnalyzeRequiresVersion2"`
}

func containsExplainString(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func validExplainStrings(values, allowed []string) bool {
	seen := map[string]bool{}
	for _, v := range values {
		if seen[v] || !containsExplainString(allowed, v) {
			return false
		}
		seen[v] = true
	}
	return true
}
func (o ExplainOptionSupport) Valid(engine string) bool {
	if engine == "postgresql" && o.PostgreSQL != nil && o.MySQL == nil {
		return validExplainStrings(o.PostgreSQL.Plan, []string{"buffers", "settings", "memory"}) && validExplainStrings(o.PostgreSQL.Analyze, []string{"buffers", "wal", "settings", "memory", "serialize", "timing"})
	}
	if engine == "mysql" && o.MySQL != nil && o.PostgreSQL == nil {
		return validExplainStrings(o.MySQL.Plan, []string{"tree", "json"}) && validExplainStrings(o.MySQL.Analyze, []string{"tree", "json"}) && (containsExplainString(o.MySQL.Analyze, "json") == o.MySQL.JSONAnalyzeRequiresVersion2)
	}
	return false
}
func validExplainFormat(engine, format string, result bool) bool {
	if format == "" {
		return true
	}
	if engine == "mysql" {
		return format == "tree" || format == "json" || result && (format == "jsonV1" || format == "jsonV2")
	}
	return (engine == "postgresql" || engine == "mariadb") && format == "json"
}

func (o ExplainOptionSupport) Accepts(options ExplainOptions, engine, mode string) bool {
	if !o.Valid(engine) || !options.Valid() || !options.ForEngine(engine) {
		return false
	}
	if pg := options.PostgreSQL; pg != nil {
		allowed := o.PostgreSQL.Plan
		if mode == "analyze" {
			allowed = o.PostgreSQL.Analyze
		}
		for key, value := range map[string]*bool{"buffers": pg.Buffers, "wal": pg.WAL, "settings": pg.Settings, "memory": pg.Memory, "timing": pg.Timing} {
			if value != nil && !containsExplainString(allowed, key) {
				return false
			}
		}
		return pg.Serialize == "" || containsExplainString(allowed, "serialize")
	}
	allowed := o.MySQL.Plan
	if mode == "analyze" {
		allowed = o.MySQL.Analyze
	}
	return options.MySQL.Format == "auto" || containsExplainString(allowed, options.MySQL.Format)
}
func validExplainSelection(s ExplainSupport, options *ExplainOptions, mode, format, status string) bool {
	if !validExplainFormat(s.Engine, format, status != "") {
		return false
	}
	if options != nil {
		if s.Options == nil || !s.Options.Accepts(*options, s.Engine, mode) || format == "" {
			return false
		}
		if my := options.MySQL; my != nil {
			selected := my.Format
			if selected == "auto" {
				selected = s.Format
			}
			if selected == "tree" && format != "tree" || selected == "json" && format != "json" && format != "jsonV1" && format != "jsonV2" {
				return false
			}
		}
	}
	if s.Engine == "mysql" {
		if status == "tree" && format == "json" || mode == "analyze" && format == "jsonV1" {
			return false
		}
		if format == "jsonV2" && mode == "analyze" && (s.Options == nil || s.Options.MySQL == nil || !containsExplainString(s.Options.MySQL.Analyze, "json")) {
			return false
		}
	}
	return true
}
