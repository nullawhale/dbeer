# Theme library validation

Source parser equivalence fixtures live in protocol/fixtures/gpui-theme-parity
and are consumed by the actual Swift and Rust parsers. Additional bounded source,
include/symlink/cycle/DTD, normalized persistence/recovery and failed replacement
cases are prepared in src/theme_library/{tests,store}.rs.

All generated temporary libraries and source trees belong under the ignored
build/gpui/task27-* directories. No real user themes, filesystem paths, query
text, results or credentials belong in these fixtures. Runtime execution is
deferred to final integration; compiled cases are not passing-run evidence.
