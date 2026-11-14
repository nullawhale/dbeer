package resultsource

import "testing"

func TestMariaDBExecutableCommentsDoNotChangeMySQLProvenance(t *testing.T) {
	sql := "SELECT * FROM fixture.items /*M! UNION SELECT * FROM fixture.other */"
	if _, reason := Parse(sql, "mariadb"); reason == "" {
		t.Fatal("MariaDB executable-comment provenance accepted")
	}
	if _, reason := Parse(sql, "mysql"); reason != "" {
		t.Fatal("ordinary MySQL comment changed its prior interpretation")
	}
	if _, reason := Parse("SELECT * FROM fixture.items WHERE payload='/*M! literal */'", "mariadb"); reason != "" {
		t.Fatal("literal comment spelling was confused with executable SQL")
	}
}
