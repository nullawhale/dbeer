# Changelog

## Next release — unreleased

- Settings → Appearance: independent application and SQL editor color schemes, live previews, and changes without restarting. The application supports System/Light/Dark and the shared scheme library: DBeer Light/Dark, VS Code Light+/Dark+, Solarized Light/Dark, JetBrains Light, Darcula, and imported themes. The application palette applies to panels, tabs, controls, and tables; the editor inherits it in Follow App Appearance mode or uses a separate scheme. Import standard VS Code JSON/JSONC, TextMate `.tmTheme`, and JetBrains `.icls` files, persist imports and selections locally, and remove custom schemes. Switching schemes preserves text, cursor position, scrolling, and Undo; the background, syntax, selection, cursor, line numbers, and completion popup use the selected palette.
- Refreshed SQL editor layout: the background fills the panel to its edges without an outer padding border, while retaining internal text padding, line spacing, the current line and its number, adaptive light/dark colors, Undo, selection, and execution highlighting.

## 0.1.0

First internal DBeer release for macOS 14+ on Apple Silicon.

- PostgreSQL 16/17/18 and MySQL 8.0/8.4, multiple profiles, and independent SQL tab sessions.
- Lazy object tree, search, structure, definitions, and table browsing with filters, sorting, and pagination.
- SQL editor with syntax highlighting, undo, completion, selection/statement execution, and sequential scripts, including stored routines.
- Drafts, `.sql` files, and managed history; restoration never connects or executes SQL.
- Chunked results with backpressure, range copying, CSV/JSON export, and a separate complete Run to File export.
- Local INSERT/UPDATE/DELETE changes, SQL preview, parameterized Apply in a separate transaction, conflict detection, and complete batch rollback.
- Secret-free profile import/export, local CA selection, and cancellable closing with transaction and pending-change handling.
- Light and dark themes, a consistent amber accent, database icons, uniform hover feedback, and native control focus handling.
- Versioned ZIP archives, SHA256 checksums, the owner's persistent signing identity, and a separate temporary CI signature.
- Swift 6.1 / Xcode 16.4 compatibility and application builds using Command Line Tools.

See [INSTALL.md](INSTALL.md) for installation instructions and the limits of the verified distribution.
