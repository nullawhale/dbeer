package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"sort"
	"strings"
)

func (r *schemaCapture) modifiers(oid string, u sc.TypeUse, mod int64, dimensions int) (sc.TypeUse, error) {
	u = pgModifiers(u, mod, dimensions)
	leaf := &u
	for leaf.Element != nil {
		leaf = leaf.Element
	}
	if leaf.Modifiers.Value == nil || leaf.Modifiers.Value.Raw == nil {
		return u, nil
	}
	if r.skipCustomTypeFormatting {
		return u, nil
	}
	// format_type invokes each type's own typmod output function. Keep both the
	// opaque integer for equality and its exact SQL spelling for previews.
	rows, e := r.rows("SELECT pg_catalog.format_type($1::pg_catalog.oid,$2::pg_catalog.int4),pg_catalog.format_type($1::pg_catalog.oid,NULL)", oid, mod)
	if e != nil || len(rows) != 1 {
		return u, sc.ErrInvalid
	}
	full, bare := rows[0][0], rows[0][1]
	if u.Kind == "array" {
		full = strings.TrimSuffix(full, "[]")
		bare = strings.TrimSuffix(bare, "[]")
	}
	if !strings.HasPrefix(full, bare) {
		leaf.Modifiers = sc.Unknown[sc.TypeModifiers]("typeModifier")
		return u, nil
	}
	suffix := strings.TrimPrefix(full, bare)
	leaf.Modifiers.Value.SQL = &suffix
	return u, nil
}

func (r *schemaCapture) typeExtension(oid string) (*sc.TypeExtension, error) {
	rows, e := r.rows("SELECT e.extname,e.extversion,n.nspname,e.extrelocatable::pg_catalog.text FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_extension e ON e.oid=d.refobjid JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace WHERE d.classid='pg_catalog.pg_type'::pg_catalog.regclass AND d.objid=$1::pg_catalog.oid AND d.refclassid='pg_catalog.pg_extension'::pg_catalog.regclass AND d.deptype='e'", oid)
	if e != nil || len(rows) == 0 {
		return nil, e
	}
	if len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	v := rows[0]
	return &sc.TypeExtension{Name: v[0], Version: v[1], Schema: sc.Ref{Kind: "schema", Schema: v[2]}, Relocatable: pgBool(v[3])}, nil
}

func (r *schemaCapture) rangeType(oid string) (*sc.TypeRange, error) {
	rows, e := r.rows("SELECT r.rngsubtype::pg_catalog.text,mn.nspname,m.typname,COALESCE(cn.nspname,''),COALESCE(c.collname,''),onsp.nspname,o.opcname,r.rngcanonical::pg_catalog.oid::pg_catalog.text,r.rngsubdiff::pg_catalog.oid::pg_catalog.text,r.rngsubopc::pg_catalog.text,r.rngcollation::pg_catalog.text FROM pg_catalog.pg_range r JOIN pg_catalog.pg_type m ON m.oid=r.rngmultitypid JOIN pg_catalog.pg_namespace mn ON mn.oid=m.typnamespace JOIN pg_catalog.pg_opclass o ON o.oid=r.rngsubopc JOIN pg_catalog.pg_namespace onsp ON onsp.oid=o.opcnamespace LEFT JOIN pg_catalog.pg_collation c ON c.oid=r.rngcollation LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=c.collnamespace WHERE r.rngtypid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	v := rows[0]
	subtype, e := r.typeUse(v[0], -1, 0)
	if e != nil {
		return nil, e
	}
	out := &sc.TypeRange{Subtype: subtype, Multirange: sc.Ref{Kind: "type", Schema: v[1], Name: v[2]}, OperatorClass: sc.Ref{Kind: "opclass", Schema: v[5], Name: v[6]}}
	if v[4] != "" {
		out.Collation = &sc.Ref{Kind: "collation", Schema: v[3], Name: v[4]}
		out.CollationProperties, e = r.typeCollation(v[10])
		if e != nil {
			return nil, e
		}
	}
	out.Canonical, e = r.typeFunction(v[7], "canonical")
	if e != nil {
		return nil, e
	}
	out.Difference, e = r.typeFunction(v[8], "subtype_diff")
	if e != nil {
		return nil, e
	}
	if pgInt(v[9]) >= 16384 {
		out.OperatorClassDefinition, e = r.typeOperatorClass(v[9])
	}
	return out, e
}

func (r *schemaCapture) baseType(oid string) (*sc.TypeBase, error) {
	rows, e := r.rows("SELECT t.typlen::pg_catalog.text,t.typbyval::pg_catalog.text,t.typalign::pg_catalog.text,t.typstorage::pg_catalog.text,t.typcategory::pg_catalog.text,t.typispreferred::pg_catalog.text,t.typdelim::pg_catalog.text,t.typelem::pg_catalog.text,COALESCE(t.typdefault,''),t.typinput::pg_catalog.oid::pg_catalog.text,t.typoutput::pg_catalog.oid::pg_catalog.text,t.typreceive::pg_catalog.oid::pg_catalog.text,t.typsend::pg_catalog.oid::pg_catalog.text,t.typmodin::pg_catalog.oid::pg_catalog.text,t.typmodout::pg_catalog.oid::pg_catalog.text,t.typanalyze::pg_catalog.oid::pg_catalog.text,t.typsubscript::pg_catalog.oid::pg_catalog.text,(t.typcollation<>0)::pg_catalog.text FROM pg_catalog.pg_type t WHERE t.oid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	v := rows[0]
	out := &sc.TypeBase{Options: sc.Complete[sc.Option](nil), Functions: []sc.TypeFunction{}}
	for i, name := range []string{"internalLength", "passedByValue", "alignment", "storage", "category", "preferred", "delimiter"} {
		out.Options.Items = append(out.Options.Items, sc.Option{Name: name, Value: v[i]})
	}
	out.Options.Items = append(out.Options.Items, sc.Option{Name: "default", Value: v[8]}, sc.Option{Name: "collatable", Value: v[17]})
	if v[7] != "0" {
		element, e := r.typeUse(v[7], -1, 0)
		if e != nil {
			return nil, e
		}
		out.Element = &element
	}
	for i, role := range []string{"input", "output", "receive", "send", "typmod_in", "typmod_out", "analyze", "subscript"} {
		f, e := r.typeFunction(v[9+i], role)
		if e != nil {
			return nil, e
		}
		if f != nil {
			out.Functions = append(out.Functions, *f)
		}
	}
	return out, nil
}

func (r *schemaCapture) typeFunction(oid, role string) (*sc.TypeFunction, error) {
	if oid == "0" {
		return nil, nil
	}
	rows, e := r.rows("SELECT n.nspname,p.proname,rn.nspname,rt.typname,l.lanname,p.prosrc,COALESCE(p.probin,''),p.provolatile::pg_catalog.text,p.proisstrict::pg_catalog.text,p.prosecdef::pg_catalog.text,p.proleakproof::pg_catalog.text,p.proparallel::pg_catalog.text,COALESCE(pg_catalog.array_to_json(p.proconfig)::pg_catalog.text,'[]'),p.procost::pg_catalog.text,p.prorows::pg_catalog.text,CASE WHEN p.prosqlbody IS NULL THEN '' ELSE pg_catalog.pg_get_functiondef(p.oid) END FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace JOIN pg_catalog.pg_type rt ON rt.oid=p.prorettype JOIN pg_catalog.pg_namespace rn ON rn.oid=rt.typnamespace JOIN pg_catalog.pg_language l ON l.oid=p.prolang WHERE p.oid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	v := rows[0]
	out := &sc.TypeFunction{Role: role, Ref: sc.Ref{Kind: "routine", Schema: v[0], Name: v[1]}, Result: sc.Ref{Kind: "type", Schema: v[2], Name: v[3]}, Arguments: []sc.Ref{}, Properties: sc.Complete[sc.Option](nil)}
	for i, name := range []string{"language", "source", "binary", "volatility", "strict", "securityDefiner", "leakproof", "parallel", "configuration", "cost", "rows", "sqlBody"} {
		out.Properties.Items = append(out.Properties.Items, sc.Option{Name: name, Value: v[4+i]})
	}
	args, e := r.rows("SELECT n.nspname,t.typname FROM pg_catalog.pg_proc p CROSS JOIN LATERAL pg_catalog.unnest(p.proargtypes) WITH ORDINALITY a(oid,ord) JOIN pg_catalog.pg_type t ON t.oid=a.oid JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE p.oid=$1::pg_catalog.oid ORDER BY a.ord", oid)
	if e != nil {
		return nil, e
	}
	for _, a := range args {
		out.Arguments = append(out.Arguments, sc.Ref{Kind: "type", Schema: a[0], Name: a[1]})
	}
	return out, nil
}

// An opclass name alone cannot identify a user range's ordering: operator
// families may be altered independently of the range and opclass objects.
func (r *schemaCapture) typeOperatorClass(oid string) (*sc.TypeOperatorClass, error) {
	rows, e := r.rows("SELECT a.amname,fn.nspname,f.opfname,tn.nspname,t.typname,o.opcdefault::pg_catalog.text,o.opcfamily::pg_catalog.text FROM pg_catalog.pg_opclass o JOIN pg_catalog.pg_am a ON a.oid=o.opcmethod JOIN pg_catalog.pg_opfamily f ON f.oid=o.opcfamily JOIN pg_catalog.pg_namespace fn ON fn.oid=f.opfnamespace JOIN pg_catalog.pg_type t ON t.oid=o.opcintype JOIN pg_catalog.pg_namespace tn ON tn.oid=t.typnamespace WHERE o.oid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	v := rows[0]
	out := &sc.TypeOperatorClass{Method: v[0], Family: sc.Ref{Kind: "opfamily", Schema: v[1], Name: v[2]}, Input: sc.Ref{Kind: "type", Schema: v[3], Name: v[4]}, Default: pgBool(v[5]), Operators: []sc.TypeOperator{}, Functions: []sc.TypeFunction{}}
	ops, e := r.rows("SELECT n.nspname,o.oprname,m.amopstrategy::pg_catalog.text,m.amoppurpose::pg_catalog.text,ln.nspname,l.typname,rn.nspname,rt.typname,o.oprcode::pg_catalog.oid::pg_catalog.text,COALESCE(sn.nspname,''),COALESCE(sf.opfname,'') FROM pg_catalog.pg_amop m JOIN pg_operator o ON o.oid=m.amopopr JOIN pg_catalog.pg_namespace n ON n.oid=o.oprnamespace JOIN pg_catalog.pg_type l ON l.oid=m.amoplefttype JOIN pg_catalog.pg_namespace ln ON ln.oid=l.typnamespace JOIN pg_catalog.pg_type rt ON rt.oid=m.amoprighttype JOIN pg_catalog.pg_namespace rn ON rn.oid=rt.typnamespace LEFT JOIN pg_catalog.pg_opfamily sf ON sf.oid=m.amopsortfamily LEFT JOIN pg_catalog.pg_namespace sn ON sn.oid=sf.opfnamespace WHERE m.amopfamily=$1::pg_catalog.oid ORDER BY m.amopstrategy,ln.nspname,l.typname,rn.nspname,rt.typname,m.amoppurpose", v[6])
	if e != nil {
		return nil, e
	}
	for _, o := range ops {
		f, e := r.typeFunction(o[8], "operator")
		if e != nil || f == nil {
			return nil, sc.ErrInvalid
		}
		op := sc.TypeOperator{Ref: sc.Ref{Kind: "operator", Schema: o[0], Name: o[1]}, Strategy: pgInt(o[2]), Purpose: o[3], Left: sc.Ref{Kind: "type", Schema: o[4], Name: o[5]}, Right: sc.Ref{Kind: "type", Schema: o[6], Name: o[7]}, Function: *f}
		if o[10] != "" {
			op.SortFamily = &sc.Ref{Kind: "opfamily", Schema: o[9], Name: o[10]}
		}
		out.Operators = append(out.Operators, op)
	}
	funcs, e := r.rows("SELECT p.amproc::pg_catalog.oid::pg_catalog.text,p.amprocnum::pg_catalog.text FROM pg_catalog.pg_amproc p JOIN pg_catalog.pg_type l ON l.oid=p.amproclefttype JOIN pg_catalog.pg_namespace ln ON ln.oid=l.typnamespace JOIN pg_catalog.pg_type rt ON rt.oid=p.amprocrighttype JOIN pg_catalog.pg_namespace rn ON rn.oid=rt.typnamespace WHERE p.amprocfamily=$1::pg_catalog.oid ORDER BY p.amprocnum,ln.nspname,l.typname,rn.nspname,rt.typname", v[6])
	if e != nil {
		return nil, e
	}
	for _, p := range funcs {
		f, e := r.typeFunction(p[0], "support_"+p[1])
		if e != nil || f == nil {
			return nil, sc.ErrInvalid
		}
		out.Functions = append(out.Functions, *f)
	}
	return out, nil
}

func (r *schemaCapture) expressionOperator(oid string) (*sc.TypeOperator, error) {
	rows, e := r.rows("SELECT n.nspname,o.oprname,COALESCE(ln.nspname,''),COALESCE(l.typname,''),COALESCE(rn.nspname,''),COALESCE(rt.typname,''),o.oprcode::pg_catalog.oid::pg_catalog.text FROM pg_operator o JOIN pg_catalog.pg_namespace n ON n.oid=o.oprnamespace LEFT JOIN pg_catalog.pg_type l ON l.oid=o.oprleft LEFT JOIN pg_catalog.pg_namespace ln ON ln.oid=l.typnamespace LEFT JOIN pg_catalog.pg_type rt ON rt.oid=o.oprright LEFT JOIN pg_catalog.pg_namespace rn ON rn.oid=rt.typnamespace WHERE o.oid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	v := rows[0]
	f, e := r.typeFunction(v[6], "operator")
	if e != nil || f == nil {
		return nil, sc.ErrInvalid
	}
	return &sc.TypeOperator{Ref: sc.Ref{Kind: "operator", Schema: v[0], Name: v[1]}, Left: sc.Ref{Kind: "type", Schema: v[2], Name: v[3]}, Right: sc.Ref{Kind: "type", Schema: v[4], Name: v[5]}, Function: *f}, nil
}

func (r *schemaCapture) typeCollation(oid string) (*sc.Collection[sc.Option], error) {
	if oid == "0" {
		return nil, nil
	}
	// JSON accommodates locale catalog fields renamed between supported server
	// versions; remove identity/ownership and compare every behavioral property.
	rows, e := r.rows("SELECT (pg_catalog.to_jsonb(c)-'oid'-'collowner'-'collnamespace'-'collname')::pg_catalog.text,COALESCE(pg_catalog.pg_collation_actual_version(c.oid),'') FROM pg_catalog.pg_collation c WHERE c.oid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return nil, sc.ErrInvalid
	}
	var properties map[string]json.RawMessage
	if json.Unmarshal([]byte(rows[0][0]), &properties) != nil {
		return nil, sc.ErrInvalid
	}
	keys := make([]string, 0, len(properties))
	for key := range properties {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := sc.Complete[sc.Option](nil)
	for _, key := range keys {
		out.Items = append(out.Items, sc.Option{Name: key, Value: string(properties[key])})
	}
	out.Items = append(out.Items, sc.Option{Name: "actualVersion", Value: rows[0][1]})
	return &out, nil
}
