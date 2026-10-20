package cassandra

import (
	"strings"
	"testing"

	gocql "github.com/apache/cassandra-gocql-driver/v2"

	"dbeer/helper/internal/protocol"
)

func TestClusterNodesSnapshotPreservesDiscoveredMetadataAndIPv6(t *testing.T) {
	makeHost := func(address, dc, rack, id string) *gocql.HostInfo {
		t.Helper()
		host, err := gocql.NewTestHostInfoFromRow(map[string]interface{}{
			"rpc_address": address, "data_center": dc, "rack": rack, "host_id": id,
		})
		if err != nil {
			t.Fatal(err)
		}
		return host
	}
	first := makeHost("2001:db8::1", "dc1", "rack1", "11111111-1111-1111-1111-111111111111")
	second := makeHost("192.0.2.2", "dc2", "rack2", "22222222-2222-2222-2222-222222222222")
	result := clusterNodesResult(protocol.Command{}, []*gocql.HostInfo{second, nil, first})
	if len(result.Rows) != 2 || len(result.Columns) != 5 || result.Columns[1].Name != "status" {
		t.Fatal("cluster snapshot lost rows or fixed column names")
	}
	if *result.Rows[0][2] != "dc1" || *result.Rows[1][2] != "dc2" || *result.Rows[1][3] != "rack2" || *result.Rows[0][4] != first.HostID() {
		t.Fatal("cluster snapshot lost metadata or datacenter ordering")
	}
	if !strings.HasPrefix(*result.Rows[0][0], "[2001:db8::1]:") || *result.Rows[0][1] != first.State().String() {
		t.Fatal("cluster snapshot changed the driver address or status")
	}
	// Taking a snapshot must not reorder or alter the driver's host collection.
	if first.DataCenter() != "dc1" || second.DataCenter() != "dc2" {
		t.Fatal("cluster inspection mutated driver metadata")
	}
}

func TestClusterNodesSnapshotIsBoundedAndHonestAboutTruncation(t *testing.T) {
	host, err := gocql.NewTestHostInfoFromRow(map[string]interface{}{"rpc_address": "192.0.2.1"})
	if err != nil {
		t.Fatal(err)
	}
	hosts := make([]*gocql.HostInfo, maxRows+1)
	for i := range hosts {
		hosts[i] = host
	}
	s := &Session{}
	response := s.catalogResponse(protocol.Command{}, clusterNodesResult(protocol.Command{}, hosts), nil)
	if !response.Truncated || response.DisplayNotice == "" || len(response.Rows) != maxRows || response.RowCount != maxRows+1 {
		t.Fatal("cluster snapshot silently lost discovered nodes")
	}
}
