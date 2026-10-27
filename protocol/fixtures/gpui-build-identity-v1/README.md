# Additive GPUI build metadata fixtures

`cases.json` indexes independent identity, build-info, optional hello.ack and
native-label cases. `valid` is expected codec acceptance, not execution evidence.
Every version, build number and digest here is synthetic. Actual product values
come from root VERSION/BUILD_NUMBER and packaging/package.py's source digest.

Canonical fixture files are sorted compact ASCII JSON followed by one LF.
Embedded executable markers omit only the final LF. Reordered and exactly
4096-byte inputs normalize to the referenced `canonical` file. Schema version
and protocol version are integer tokens, not strings, booleans or floats.
Version components permit leading zeroes; build numbers do not. Twenty-digit
build numbers are strings and never lose numeric precision.

Invalid cases intentionally contain malformed JSON, duplicate/escaped keys,
invalid types/semantics and bounds. `invalid-utf8.bin` contains one invalid UTF-8
byte. Parse the index and run its selected codec rather than assuming every
fixture file is valid JSON. The 4097-byte oversize file must be refused before
normalization. Valid Windows/Linux values are portable metadata and may be
parsed on Mac; that does not authorize native product runtime validation there.

Go consumer: helper/internal/productidentity/identity_test.go.
Swift consumer: macos/Tests/DBeerTests/GPUIProductBuildIdentityTests.swift.
Rust consumer: prototypes/gpui/src/product_identity/contract_fixtures.rs, now
declared by product_identity.rs. The actual Rust and Swift transport decoders
also consume the optional hello cases before general value decoding. Additional
hello cases nest invalid build, source, target, capability and semantic revision
values, a 4097-byte original identity and an escaped duplicate outer type.
No existing shared fixture or frozen parity baseline is replaced.
