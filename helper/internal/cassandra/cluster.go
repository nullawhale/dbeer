package cassandra

import (
	"sort"

	gocql "github.com/apache/cassandra-gocql-driver/v2"

	"dbeer/helper/internal/protocol"
)

// Status is the current driver's view, not a cluster-wide health assessment.
// GetHosts includes discovered down hosts; reading it performs no CQL or probes.
func clusterNodesResult(command protocol.Command, hosts []*gocql.HostInfo) protocol.ResultSet {
	rows := make([][]*string, 0, len(hosts))
	for _, host := range hosts {
		if host == nil {
			continue
		}
		status := "UNKNOWN"
		switch host.State() {
		case gocql.NodeUp:
			status = "UP"
		case gocql.NodeDown:
			status = "DOWN"
		}
		rows = append(rows, cells(host.ConnectAddressAndPort(), status, host.DataCenter(), host.Rack(), host.HostID()))
	}
	sort.Slice(rows, func(i, j int) bool {
		for _, column := range []int{2, 3, 0, 4} {
			if *rows[i][column] != *rows[j][column] {
				return *rows[i][column] < *rows[j][column]
			}
		}
		return false
	})
	return stringsResult(command, []string{"address", "status", "datacenter", "rack", "hostId"}, rows)
}
