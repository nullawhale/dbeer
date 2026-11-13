# Schema bundle v1

`schemaBundleV1` adds `schema.bundle.start`, `status`, `export`, `cancel` and
`close` commands inside the existing `schemaComparison` envelope. A start request
contains one explicit source connection and one to 32 exact schema names. SQLite
accepts only `main`. A bundle owns one dedicated read-only catalog capture; it
never uses a SQL tab's session or starts from workspace restoration. Capture and
bundle construction have a two-minute deadline. At most two schema jobs are
retained by one helper.

The completed status contains `bundleSummary`, with engine, sorted selected
schemas, the manifest descriptor, included/omitted/incomplete counts and total
bytes. Export requests contain an exact file ID and bounded offset/maxBytes.
Replies use the existing chunk shape with file ID, SHA-256, total bytes, offsets,
base64 bytes and `hasMore`. Only manifest/capture IDs and IDs declared in the
retained manifest are readable. Native code binds every chunk to its request,
file descriptor and digest. Credentials and connection provenance are absent from
all exported files.

A directory contains these UTF-8 files:

- `manifest.json`: versioned typed object report, logical namespaces, capture
  descriptor, object descriptors, dependency states, issues, coverage and scope.
- `capture.json`: the complete typed portable catalog snapshot used by schema
  comparison, including metadata needed for external dependencies.
- One `.sql` file per selected schema/table/type/sequence root. Supported complete
  definitions come from the existing engine renderer. An omitted or incomplete
  definition is replaced entirely with a constant SQL comment. No executable
  prefix from an incomplete preview is retained.

Each file descriptor contains `id`, `path`, integer byte count and lowercase
SHA-256. The manifest descriptor is returned in status rather than recursively
included inside the manifest. Object paths contain a bounded ASCII name prefix
and the full SHA-256 of the original exact UTF-8 typed reference. They are flat,
under 101 ASCII bytes and distinct for case differences, Unicode normalization
forms and names too long for ordinary filesystem components. Display prefixes do
not participate in identity.

All bytes are stable for the same captured semantic schema. Portable context
retains engine, semantic engine options, consistency and visibility; its runtime
version, connection default database and capture clocks are empty. Logical
schema/database names remain in inventories and every qualified reference.
Unordered inventories, objects, constraints, indexes, options, dependencies and
issues are sorted deterministically. Column/composite-key/index-key/argument/
enumeration order and exact numeric/expression strings retain their semantics.
Capture IDs, database-local addresses, statistics and current sequence or
AUTO_INCREMENT counters do not enter portable identity.

Only selected schema roots receive files. Captured PostgreSQL referenced types
and sequences outside the selection remain in the snapshot and appear as
`external` dependencies. Table row types retain their metadata and refer to the
owning table. An object with an unavailable, omitted or incomplete user dependency
is itself incomplete; its SQL is comment-only. Engine built-in references are
marked `builtin`. Dependencies within the bundle state the referenced object's
actual included/omitted/incomplete state. Schema creation options/ownership,
views, routines, privileges, statistics and physical rows are outside the current
scope; PostgreSQL/MySQL triggers are also excluded. SQLite's exact table/index/
trigger definitions stay together in their table file. These scoped files are
reviewable source artifacts, without an automatic apply operation or execution
ordering guarantee.

SQLite dependency coverage comes from bounded preparation of INSERT/UPDATE/
DELETE and ordered SELECT programs; no prepared program is stepped. SQLite
resolves table/index/default/generated/check/trigger programs and nested views.
Canonical global trigger identities distinguish trigger accessors from view
candidates; unresolved collisions, unobserved triggers and unavailable functions
retain explicit incomplete coverage rather than invented references. Ordinary
provable tables, expression indexes, safe triggers and FK parents stay included.
The dedicated capture restores readonly authorization, interruption and its
original connection-local foreign-key setting even on cancellation or quota
failure. Current rows and sequence counters remain untouched.

Capture quotas are 10,000 nodes, 100,000 members, 64 MiB encoded captured metadata
and 1 MiB per scalar. SQLite program probes obey the same scalar/member/byte
limits and inherit the adapter's bounded catalog reads. Bundle quotas are 10,000 roots, 128 MiB total files, 8 MiB
manifest, 128 KiB per SQL definition and 1 MiB maximum chunk. Native downloads use
64 KiB chunks and retain only the bounded manifest in memory. Completed files do
not keep one descriptor per object open.

Publication targets a new local directory only. Native code retains parent and
private staging directory ownership, verifies file sizes/hashes and identities,
then uses an exclusive atomic sibling rename. Bulk whitelist/hash verification
and synchronization run off the main actor before and after rename, with Stop
and source-context checks between files and each 64 KiB read. The brief rename
and final success admission run on the main actor with the current context; a
late cancellation before confirmation rolls back only an owned publication.
An acknowledged commit remains confirmed after a later Stop. Every final file is
private mode 0600 and the directory mode 0700. Existing destinations, changed parents,
replacement roots and failed/obsolete downloads do not authorize overwriting
external files. Detached cleanup only removes owned private inodes.

`schema-bundle-v1.json` is shared by strict Go request tests and native protocol,
manifest, checksum and export tests. Its base64 file payloads are synthetic
fixtures, not captured user data.
