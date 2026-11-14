package mariadb

import "testing"

func TestMariaDBDataNativeVersionFloors(t *testing.T) {
	for _, tt := range []struct {
		version, comment string
		want             bool
	}{
		{"10.11.9-MariaDB", "MariaDB", true}, {"10.11.14-MariaDB-ubu2204", "mariadb.org binary distribution", true}, {"11.4.3-MariaDB", "MariaDB", true}, {"11.4.8-MariaDB", "MariaDB", true},
		{"10.11.8-MariaDB", "MariaDB", false}, {"11.4.2-MariaDB", "MariaDB", false}, {"10.6.19-MariaDB", "MariaDB", false}, {"12.0.0-MariaDB", "MariaDB", false}, {"8.4.7", "MySQL Community Server", false}, {"5.5.5-10.11.9-MariaDB", "MariaDB", false}, {"11.4.3garbage", "MariaDB", false},
	} {
		if supportedNativeVersion(tt.version, tt.comment) != tt.want {
			t.Fatal("native server support floor or flavor changed")
		}
	}
}
