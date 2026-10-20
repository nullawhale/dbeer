# Portable connection profiles, versions 1 and 2

SwiftUI/AppKit and the experimental Windows/Linux GPUI client share this
metadata-only JSON format. It is independent of either application's private
library version or credential service. Files contain no IDs, passwords, client
private keys, SQL, results, sessions or connection state. Unknown fields,
including secret fields, are errors rather than ignored extensions.

The envelope has exactly `version` and `profiles`. Export uses version 2:

```json
{
  "version": 2,
  "profiles": [{
    "name": "Team PostgreSQL",
    "engine": "postgresql",
    "host": "pg.example.test",
    "port": 5432,
    "database": "brewery",
    "user": "analyst",
    "sslMode": "verify-full",
    "sslRootCert": "/home/example/ca/team.pem",
    "policy": {"environment": "production", "readOnly": true}
  }]
}
```

Every shown profile field except `sslRootCert` is required in v2. Policy has
exactly `environment` and `readOnly`; environments are `unspecified`,
`development`, `staging` and `production`. An omitted or null `sslRootCert`
means system roots. It never means permission to remove a supplied CA hint.
Version 1 permits omitted/null policy, which means **unspecified/false**, matching
the frozen Swift transfer behavior. An explicit v1 policy is preserved. The old
GPUI **private-library** development/true migration defaults do not apply to
portable transfer. In v2, omitted/null/partial policy is invalid.

Inputs must be UTF-8 JSON, at most 2 MiB, with 1–1,000 profiles. Reject repeated
object keys, including escaped spellings, at every level before they can be
collapsed into a dictionary; unknown keys, trailing data, invalid scalar types
and nesting of 16 or more recursive value levels are refused. Names, hosts,
databases and users are nonblank, NUL-free and at most 1,024 UTF-8 bytes; names
also have at most 128 extended grapheme clusters. Ports are integers 1–65,535.
Engines are `postgresql` and `mysql`. PostgreSQL TLS modes are `disable`, `allow`,
`prefer`, `require`, `verify-ca` and `verify-full`; MySQL excludes `allow` and
`prefer`. No validation error includes imported data or parser/OS payloads.

## CA hints and remapping

`sslRootCert` is a public CA **path hint**, not certificate content, a portable
filesystem capability or a reason to change TLS verification. Accept these
absolute syntaxes on every OS, with a 4,096-byte/NUL-free bound:

| Syntax | Example | Local interpretation |
| --- | --- | --- |
| POSIX | `/home/example/ca/team.pem` | Local only on macOS/Linux |
| Windows drive | `C:\CA\team.pem` or `C:/CA/team.pem` | Local only on Windows |
| Windows UNC | `\\certificate-host\public-ca\team.pem` | Requires explicit native chooser remapping before any probe, including on Windows |

Drive-relative/root-relative paths, URLs, incomplete UNC server/share names and
Windows device namespaces (`\\?\`, `\\.\`) are invalid. Hint strings are
preserved exactly until a user chooses a replacement; there is no expansion,
separator rewriting, path guessing or automatic certificate copying. POSIX
syntax starts with `/`; UNC syntax uses two leading backslashes and nonempty
server/share components without `/` or `:`. Foreign hints must never be passed
to filesystem APIs during preview. A foreign path, absent/unreadable CA or a
directory requires explicitly selecting a readable native regular file. The
selected path replaces the hint without changing `sslMode`, engine or policy.
A supplied hint cannot be cleared as an import shortcut. Recheck selected CAs
at publication so removal after preview refuses the entire batch rather than
silently falling back to system trust.

A Mac → Windows → Linux → Mac journey therefore keeps required TLS/policy
values but normally selects a different local public CA at each stage. Sharing
the same bytes or file name is not proof of equivalent trust. The synthetic
`fixtures/profile-transfer/*-v2.json` stages record these explicit remaps, and
`legacy-v1.json` records omitted, null and explicit legacy policies. Both Swift
and Rust consume the same files. `invalid/` contains bounded malformed and
synthetic secret-field rejection fixtures; none contains actual credentials.

## Publication

Preview allocates fresh identities and has no storage/credential/session side
effects. Review supports individual/all selection and Cancel. Each actual import
allocates fresh saved identities again and appends disconnected profiles. It
never overwrites a saved record or credential. GPUI publishes the entire selected
batch in one owner-serialized private-library replacement, preserving concurrent
additions and current selection, refusing changed/deleted original records and
never touching the credential store. A new missing password authenticates as an
empty password when the user later explicitly connects, matching Swift behavior.

Export captures the original selected settings before opening the native save
chooser and validates the complete file before writing. GPUI syncs a private
same-directory temporary file and atomically renames it to the destination.
Cancel and failed preparation/replacement leave the original unchanged; no copy
or delete-first replacement fallback is permitted. Native choosers and callbacks
retain the original workspace/review and row identity. A cancelled/replaced
preview cannot receive a late CA selection or begin an import.

Implementation/compilation and executed/native evidence remain separate; see
`prototypes/gpui/IMPLEMENTATION.md`. These fixtures and instructions are tracked;
no build or test depends on ignored planning documents.
