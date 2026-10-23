# DBeer Cassandra driver snapshot

This directory contains production Go sources from
[`github.com/apache/cassandra-gocql-driver/v2` v2.1.2](https://github.com/apache/cassandra-gocql-driver/tree/v2.1.2),
upstream commit `590aabedfaa33398e308e253e0bda020a8dbcafe`.
The upstream module checksum is
`h1:lu/p0Db2av18enHJvWJQoChLssI0P+AR06STq4VdvCc=`.
`go.mod`, `go.sum`, `LICENSE`, and `NOTICE` are preserved from that version.
DBeer's `helper/go.mod` replaces only this module with the local directory.

The snapshot retains the driver package and its internal runtime packages. It
omits optional logger, compression, and host-pool adapters unused by DBeer,
upstream tests, examples, certificate fixtures, fuzz and generator programs,
and the test-only CCM package. No embedded resources are required. The only
local test file is `custom_wire_type_test.go`.

The local patch adds an optional `ClusterConfig.CustomWireTypeResolver`. Each
session receives its own copied type registry and callback. Wire `TypeCustom`
metadata reaches the callback with its original full Java class spelling and
the registered decoder or unknown-class error. Broken metadata, invalid vector
dimensions, and other decoder errors still fail before the callback. With no
callback, upstream behavior is unchanged.

DBeer opts in to retain unknown custom classes and legacy aliases as opaque
bytes. It keeps the native vector codec and stores the original class spelling
in the optional `VectorType.WireCustomClass` field, which does not change
marshalling. This preserves aliases inside vector parameters in saved-result
type identity. External Java implementation equivalence remains unresolved.
The registry is never modified globally or after session creation.

`DBEER.patch` records the complete runtime change against the pinned upstream
source. It can be reviewed separately from the copied source tree.

Verification from the repository root:

```sh
go -C helper/third_party/cassandra-gocql-driver test -race -run CustomWire -count=1 .
go -C helper test -race -count=1 ./internal/cassandra ./internal/schemacompare
./scripts/test-cassandra.sh --version 5.0 --mode plain -- \
  go -C helper test -race -count=1 -run '^TestCassandraLiveSchemaAndDataComparisonTypes$' ./internal/cassandra
```

The driver boundary tests cover unknown classes, legacy aliases, nested custom
types, exact bytes and NULL/empty distinction, native vectors, malformed and
truncated metadata, and opt-in isolation. Cassandra adapter tests additionally
cover opaque rendering, unresolved semantic identity, and vector class identity.
