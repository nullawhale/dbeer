package protocol

import (
	"strings"
	"testing"
)

func TestMariaDBObservationAdmissionIsNativeFingerprintOnly(t *testing.T) {
	r := SchemaObservation{Engine: "mariadb", Action: "poll", Tables: []SchemaObservationTable{{Schema: "fixture", Name: "t"}}, Mode: "fingerprint", Revision: strings.Repeat("a", 64), ObservedAt: "2026-11-14T00:00:00Z", Complete: true, Notices: []string{}}
	if !r.Valid() {
		t.Fatal("native fingerprint observation refused")
	}
	for _, change := range []func(*SchemaObservation){func(r *SchemaObservation) {
		r.Action = "previewInstall"
		r.Tables = []SchemaObservationTable{}
		r.Mode = "notifications"
		r.SQL = "native setup"
		r.Revision = ""
	}, func(r *SchemaObservation) { r.Installed = true }, func(r *SchemaObservation) { r.CanInstall = true }, func(r *SchemaObservation) { r.Mode = "notifications" }} {
		bad := r
		change(&bad)
		if bad.Valid() {
			t.Fatal("PostgreSQL notification setup escaped into native fingerprint engine")
		}
	}
}
