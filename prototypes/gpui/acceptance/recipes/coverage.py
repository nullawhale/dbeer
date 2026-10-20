"""Complete frozen assertion planning table, with explicit integration debts.

This module only builds/validates data in memory. It never runs a scenario,
creates a ledger, changes review flags, reads native trees or inspects secrets.
"""
from __future__ import annotations

import json
from pathlib import Path

REQUIREMENTS = {
    "native-bindings": "Observe each exact previous/candidate artifact's real UIA/AT-SPI roles, names, hierarchy, actions and optional proven native IDs. Source ElementIds cannot supply native IDs. Check original window/modal lifetime before every action; new modal lifetime gets a new key. Typed NULL/text NULL require semantic kind/description, not equal text hashes alone.",
    "captured-uuid": "Bind assert-profile-policy profileId from a genuinely new UI-created captured UUID, validated against the current isolated library. Workflow now resolves these through genuine before/after discovery, current isolated membership and capture epochs; never substitute a literal UUID.",
    "expected-metadata": "Add exact expected columns to observer and native result assertions; compare complete ordinal/name/engine/type/OID/encoding AND rows against recipes/oracle.py. Workflow now binds independent snapshot/export/effect metadata oracles; explicit-row assertions require nonempty independently supplied columns.",
    "fixed-inputs": "Stage only enumerated fixture inputs under the owned private inputs directory and register their exact fixed input keys. Workflow now resolves enumerated bounded corpus strings and explicitly staged pinned shared sources. Native range/language consumers still require their concrete join.",
    "source-state": "Assert exact persisted expected subsets/deltas and UI live typed states: UUID membership/order/selected stable IDs, source/title hashes, history entries, settings DTOs, disconnected state and absence of live session/results/secrets. capture-state equality alone cannot establish new expected values or in-memory carets/Undo.",
    "lifecycle": "Retain exact GUI children and canonical owner across reviewed common Close/restart. Fresh fixed corrupt/future profile/workspace/appearance/library/shortcut subfixtures now use exclusive private roots, original file handles, normal subfixture Close and unchanged main-state restoration. Native selectors/actions remain unobserved. Never use force-stop as rollback/flush evidence.",
    "credential-update": "Extend owned credential journal with conditional expected-prior-hash UI update/keep/empty/delete intents and exact observed terminal hashes, including metadata failure rollback. Workflow now supports first-write and conditional current-owned-hash update/delete intents with explicit terminal write/delete/keep/rollback verification. Never adopt a collided/unowned credential or read password controls.",
    "file-fault": "Held original file/parent identities and bytes, fresh exact recovery backup discovery and Windows deny-write/delete-sharing barriers are integrated. Original receipts allow explicit app replacement; the separate barrier blocks it. Ambiguous publication, backup-failure and safe external conflict branches still need their exact owned adapters/observations. No arbitrary path writes or broad cleanup; recovery is explicit.",
    "startup-pipe": "Add exact GUI startup modes with bounded anonymous stdin pipe: ordinary unreadable/blocking pipe, explicit synthetic connect, 65537-byte overflow and incomplete timeout. Credentials remain pipe-only; independently count connections/fixture effects and inspect sanitized process metadata without dumping argv/env.",
    "session-observer": "Fixed direct observers now capture original server/image plus physical session-set deltas; PostgreSQL includes backend creation and exact idle/open/failed transaction state. MySQL PROCESSLIST supplies neither creation time nor transaction ownership, and those fields are never invented. Exact per-tab/service role correlation, temp state and MySQL transaction witnesses remain required.",
    "owned-effects": "Install only reviewed fixed acceptance-effects SQL into exact OwnedDatabases receipts with original nonce label and synthetic MySQL grants, then expose fixed readonly effect queries. OwnedDatabases.setup_acceptance_effects now accepts only its original exact receipt and one-shot fixed pinned source. Workflow effects-setup and fixed readonly effect/receipt oracles consume this API; no arbitrary request SQL is authorized.",
    "script-trace": "Prove the exact frozen execution behavior using independently expected original native source/range/result identities and fixed ordered server receipts. Existing success/first-error/middle-error receipts prove which later fixed writes were skipped; an internal request trace is not required for that behavior. Zero read-only work needs an independent bounded query-delta witness, not merely zero final effects or before/after sessions. Do not log SQL/results or require AppKit-specific instrumentation.",
    "fault-boundary": "Installed SQL COMMIT uses an original one-connection opaque relay: hold before one fixed Commit, independently observe effect1, drop exact sockets and require original Unknown/retry-disabled/stableeffect1/sessiongone. Apply explicitly pins original catalog, admits one fresh native-prepared second lease/review, gates only its exact reverse chunks and releases each prior chunk only after fresh effect0; effect1+exactrows holds/drops current+later bytes while catalog survives. Exact trusted paired source provenance/sequential adapters are checked. Native lease/role observations and precise other fault phases remain required; no fake peer or retry while unknown.",
    "helper-lifetime": "Installed helper death still requires the actual packaged GUI-owned original OS handle/creation/image receipt; do not discover descendants/PIDs. Separate native real-Go tests retain the runner source file identity/hash and original BackendClient Child, observe physical sleep, retire/reap it, verify Unknown/no reconnect and exact DB-session loss while observer survives. Those native headless tests cannot supply installed-helper ownership evidence.",
    "text-range": "Guarded original UIA TextPattern/AT-SPI Text selection and UTF-16 reads now compare fixed independent source/range hashes, reject split surrogates and retain observed native identity. UIA locates provider-defined Character endpoints by measured UTF-16 prefixes. Real keyboard/Undo/IME, visible text-run geometry, scrolling and gutter ownership remain native gates.",
    "typed-grid": "Original native semantic reads now compare independently expected description/name hashes, enabled/readonly/selection and realized row/column/span/count fields; unsupported native fields refuse. Windows description property must be independently observed, not silently aliased. Full original typed editor/Preview/Apply procedures and row/result/snapshot correlation remain required; text NULL cannot stand for SQL NULL.",
    "server-browse": "Add fixed readonly page/filter/catalog observers and exact captured table identity; nine filters must compare source-derived selected PK arrays/counts under stable PK tie-break order, including invalid typed input with zero request delta. UI row count alone is insufficient.",
    "clipboard": "Manual-owned native clipboard capture/restore with enumerated exact MIME formats, typed ordinal/null/binary JSON and independently encoded TSV; no global clipboard operations exist in this harness. Do not infer clipboard success from semantic Copy invocation.",
    "language-oracle": "Join exact shared parser/completion/signature expected fixtures and independently expected scope/ranking/quoting/UTF-16 spans to original native UI. Retain owned LSP process lifetime/environment and stale-result behavior where the frozen assertion requires them. Missing internal protocol instrumentation alone is not a parity failure; typing performs zero DB work only with an independent query-delta witness, not final effects alone.",
    "settings-oracle": "Complete independent appearance/shortcut/library DTOs, fixed normalized RGBA/scopes/styles including explicit empty font style, genuine committed imported UUID discovery and latest full DTO checks after common Close/restart are integrated. Compare actual native controls/rendered palettes and all frozen shared imports/recovery behaviors to independent expectations. An internal held-publication/reservation trace is not an added frozen assertion; group existence or a captured app-written baseline is insufficient.",
    "native-manual": "Retain actual per-target keyboard/Return/Escape/Undo, IME/AltGr/dead key, file chooser, screen-reader, focus/hover/contrast/DPI and window/OS appearance observations where required. Native semantic Invoke/SetValue and headless tests cannot supply them; no fabricated/manual auto-pass flag.",
    "package-evidence": "Join exact trusted prior/candidate archive/manifest/build/native resources, runtime/GPU/standard-user dependency observations, safe integration/remove file receipts and concurrent old/new ownership checks. Existing core verifies much of this but assertion join must be explicit.",
    "matrix-join": "Strict completed-summary consumers cover native Task30 Rust default/native-smoke with all thirteen exact portable faults once per mode, all seven versioned DB/TLS stages including original real-helper death/catalog/signature assertions, the same-owned-pair supported Go race stage with all ten exact critical assertions and actual Mac SwiftUI/Go/Swift Testing completion. Installed/manual/physical final aggregate producers remain missing. All171 exact native cells are required; zero/partial/duplicate/skipped/headless summaries cannot become native acceptance.",
}

# Order is intentionally one-to-one with each frozen step's assertions. A count
# change refuses catalog construction instead of silently dropping assertions.
CHECKS = {
    "F01": [
        ("After metadata-only Save, both independent servers have zero product sessions and the UI-created profile has no reserved credential.", "captured-uuid"),
        ("Save & Connect creates exactly one new physical product session for the captured profile, no SQL effects, then Disconnect returns its count to zero.", "session-observer"),
        ("Saved original UUID has readonly=true, environment=development, sslMode=verify-full and the exact owned CA path after name edits on each engine.", "captured-uuid"),
        ("Before/after canceled edit typed profile/workspace hashes and already-owned credential hash are equal.", "credential-update")],
    "F02": [
        ("Record actual two profile/three document UUIDs; after native reorder and normal restart the exact ordered UUID list and source hashes equal the chosen permutation.", "source-state lifecycle"),
        ("Select captured middle document/profile ID; remove first profile and compare selected ID to its original capture, not a new vector offset.", "source-state lifecycle"),
        ("All restored documents expose disconnected state and both physical server product connection counts are zero before explicit connect.", "source-state lifecycle")],
    "F03": [
        ("Untouched newly UI-created original profile persists readonly=false, environment=unspecified, sslMode=verify-full for both engines.", "captured-uuid"),
        ("For each of eight explicit environment/readOnly pairs, import keeps the exact pair; existing development/true record is byte-policy unchanged.", "captured-uuid fixed-inputs"),
        ("Portable v1 missing/null policy yields unspecified/false; legacy private-library migration uses its separately frozen rules and preserves explicit values.", "fixed-inputs source-state")],
    "F04": [
        ("Fresh absent credential verifies absent=true/empty=false; separate UI empty write verifies absent=false/empty=true and nonempty verifies exact known hash.", "credential-update"),
        ("Owned metadata publication failure after replacement restores exact previous credential hash and prior metadata bytes/selection.", "credential-update file-fault"),
        ("Inject exact owned rollback/delete failures; fixed visible error plus original/attempted journal hashes keep recovery pending, never success.", "credential-update file-fault"),
        ("Strict persisted metadata field allow-list and bounded private diagnostic hash-only audit find no synthetic password bytes or private key fields.", "source-state credential-update")],
    "F05": [
        ("Stage exact legacy fixture before launch; exclusive backup SHA equals original bytes and every original opaque profile ID remains unchanged.", "file-fault lifecycle"),
        ("After failed load and attempted UI mutation, exact corrupt/future input inode/hash remains unchanged and recovery remains explicitly required.", "file-fault lifecycle"),
        ("Injected atomic replacement failure preserves prior connection bytes, captured selectedProfileId and owned credential hash.", "file-fault source-state")],
    "F06": [
        ("Strict v1/v2 transfer-check over both profile records accepts only metadata/TLS/policy fields; exact password/private-key/UUID fields are absent.", "fixed-inputs"),
        ("Run every shared invalid transfer source plus count/depth/size boundaries; no accepted rows, new IDs, credential writes or library byte changes.", "fixed-inputs source-state"),
        ("Accepted UI imports generate unique IDs disjoint from source/prior IDs; exact metadata/policy preserved, no credential created, both DB session counts zero.", "captured-uuid source-state"),
        ("Capture typed state and reserved credential hashes before import review; one/all selection followed by Cancel changes neither.", "credential-update")],
    "F07": [
        ("Shared Windows/POSIX CA hints remain unresolved metadata on the other OS; actual saved trusted path is absent until chooser confirms owned remap.", "fixed-inputs source-state native-manual"),
        ("Attempt Connect before remap is refused with zero physical connections; explicitly selected actual CA maps only the original imported profile.", "native-manual captured-uuid"),
        ("Every transfer/remap/cancel stage retains original verify-ca/verify-full; no implicit disable/require downgrade; trusted host succeeds, mismatch fails.", "captured-uuid fault-boundary"),
        ("Cancel native remap leaves original profile UUID, all metadata bytes, credential hash and CA trust policy unchanged.", "native-manual credential-update")],
    "F08": [
        ("Ordinary startup with unreadable and blocking stdin completes with zero read/connection/effect counters, without fabricated timeout success.", "startup-pipe"),
        ("One explicit valid anonymous-pipe payload yields one physical connection and zero fixed effect receipts; no SQL is replayed.", "startup-pipe owned-effects"),
        ("65537-byte payload and incomplete five-second timeout exit/refuse boundedly; retry new exact owned child accepts a valid payload once.", "startup-pipe lifecycle"),
        ("Credential hashes are pipe-only; sanitized startup/child metadata and private structural diagnostic audit confirm no secret argv/env/log bytes.", "startup-pipe")],
    "F09": [
        ("Tab A and B physical backend IDs differ; A transaction/temp/session setting remains, B lacks that temp/setting and is idle on each engine.", "session-observer fixed-inputs"),
        ("Switch active profile/tab during two original operations; each result/terminal hash is attached to its captured UUID/query/session owner only.", "fault-boundary script-trace"),
        ("Disconnect B removes only its physical backend; A backend and catalog service IDs remain alive with original state and exact row effects.", "session-observer")],
    "F10": [
        ("Catalog and completion metadata share the captured service physical backend and never the SQL tab A backend.", "session-observer"),
        ("Apply's independently observed backend is distinct, idle before begin and gone after acknowledged cleanup; fixed table delta is exact.", "session-observer owned-effects"),
        ("A original backend remains in its uncommitted transaction with exact original temp/session setting and observer cannot see A uncommitted write.", "session-observer")],
    "F11": [
        ("Over-row/byte/set corpus plus held chunk ACK has maximum retained rows/bytes/sets at declared limits and bounded pending-frame counters.", "helper-lifetime script-trace fixed-inputs"),
        ("Observe one physical sleep/stream before Stop, then zero and one exact original-operation terminal despite held ACK; bounded control latency recorded.", "helper-lifetime fault-boundary"),
        ("Partial completed set hashes remain in order; authoritative terminal transaction status matches physical original session after cancellation/death.", "session-observer expected-metadata helper-lifetime"),
        ("Every bounded operation exits/completes within its explicit deadline; exact owned helper death produces a terminal rather than a timeout-derived pass.", "helper-lifetime")],
    "F12": [
        ("For tab/profile/window/app scopes and idle/open/failed transactions, Cancel retains exact original backend/transaction/source and no committed delta.", "session-observer lifecycle native-manual"),
        ("Separate Roll Back/Commit cases produce fixed effect counts 0/1 and exactly one original resolution/disconnect terminal per scope.", "owned-effects script-trace lifecycle"),
        ("Repeated Quit while held commit/disconnect keeps the original decision token, produces no second commit and preserves observer receipt count one.", "fault-boundary script-trace lifecycle"),
        ("Retained exact GUI exits normally only after its captured disconnect acknowledgment and independent product backend count zero.", "session-observer lifecycle")],
    "F13": [
        ("Native keyboard dialog default focus is Cancel for running/edit/export/unknown cases; Enter/Escape observations retain that safe decision.", "native-manual"),
        ("All affected original operation/draft/export/session tokens resolve once under Stop/Apply/Discard; fixed observer effects match selected resolution for each close scope.", "owned-effects fault-boundary lifecycle"),
        ("After real lost ACK, retry/reapply stays disabled; repeated close cannot issue another mutation, receipt count remains exactly one.", "fault-boundary owned-effects"),
        ("Cancel restores original document/result/snapshot selection/focus; uncommitted drafts and source hashes remain, with no observer mutation.", "source-state typed-grid native-manual")],
    "F14": [
        ("Original native text and persisted source equal the fixed non-BMP/combining/CRLF straight-quote/dash corpus hash in two tabs.", "fixed-inputs source-state"),
        ("Native paste/typing retains exact apostrophe/quote/dash bytes; no smart substitutions or correction occur.", "native-manual fixed-inputs"),
        ("Expected UTF-16 caret/selection and original logical line number are derived from corpus CRLF/non-BMP boundaries and compared to native gutter.", "text-range"),
        ("Different selections/scroll/source edits in two UUIDs survive switches/themes; one native Undo reverts only its original tab edit.", "text-range native-manual")],
    "F15": [
        ("All shared sql-execution corpus resolved ranges/SQL hashes equal fixed expected byte+UTF16 spans for toolbar/menu/keyboard/Run-to-File entry points.", "fixed-inputs text-range script-trace native-manual"),
        ("Nonempty selected range hash is used even when caret lies inside another statement; zero selection uses frozen caret boundary cases.", "text-range script-trace"),
        ("Displayed range highlight and summary source hash refer to original captured tab/revision and fixture UTF-16 spans, including just after semicolon.", "text-range script-trace")],
    "F16": [
        ("Fixed parser fixture ordered statement hashes equal physical receipt/command trace; routine-body embedded delimiters never become extra statements.", "fixed-inputs script-trace owned-effects"),
        ("MySQL DELIMITER directives appear in neither sent statement hashes nor physical effects; frozen directive-stripped ranges match.", "fixed-inputs script-trace"),
        ("Every unsupported client-command/unterminated case yields expected original source diagnostic span, zero execute delta and no effects.", "fixed-inputs text-range script-trace")],
    "F17": [
        ("Review shows fixed ordered allowed/write/destructive/unknown classification and whole batch/source/profile hash, not a per-statement grant union.", "fixed-inputs script-trace"),
        ("Native default focus and Return/Escape follow Cancel; no grant consumption or physical mutation occurs on Cancel.", "native-manual owned-effects"),
        ("After SQL edit/Stop/profile switch/error before remaining work, old grant cannot authorize any later statement; fixed skipped receipts remain absent.", "fault-boundary script-trace owned-effects")],
    "F18": [
        ("Fixed success/first-error/middle-error scripts produce ordered receipt arrays [first,middle,last], [], [first]; first duplicate-key failure is terminal.", "owned-effects script-trace fixed-inputs"),
        ("Completed result sets compare exact independent columns/rows/command tags in statement order; MySQL procedure has two data sets plus explicit terminal status.", "expected-metadata script-trace"),
        ("After first/middle failure, independently expected ordered receipt arrays remain []/[first], and the distinct later fixed receipt is absent; this establishes skipped fixed statements without an internal request trace.", "owned-effects script-trace"),
        ("Switch tabs under held results; every set retains original statement index/document/session/query IDs and old result publication cannot replace newer capture.", "fault-boundary script-trace")],
    "F19": [
        ("Fixed source places a second statement failure after emoji/CRLF; error/success gutter range equals independent fixture UTF-16 offset.", "text-range fixed-inputs"),
        ("Caret navigation to expected diagnostic line preserves original document and correct CRLF logical current line.", "text-range"),
        ("After success then one source edit, old success mark is absent and no stale reply can restore it for a newer source revision.", "text-range fault-boundary")],
    "F20": [
        ("Two native file Open/Save-As workflows retain distinct exact owned path/file identity receipts per original document UUID.", "file-fault native-manual source-state"),
        ("Saved file bytes and editor/persisted hashes equal fixed UTF-8/emoji/combining/CRLF corpus, with no newline normalization.", "file-fault fixed-inputs"),
        ("Chooser Cancel, invalid UTF-8 and locked destination preserve original file stamp/hash, editor source, binding and selected original document.", "file-fault native-manual source-state")],
    "F21": [
        ("After observable persisted debounce completion and awaited normal-close flush, exact UUID/order/selection/source hashes restore; both servers report zero product sessions.", "source-state lifecycle"),
        ("Strict source-only document/workspace schema excludes results/session/transaction/password fields; no native credentials are accessed by restoration.", "source-state"),
        ("Original fixed effect counters and execute trace delta remain zero through ordinary startup/restart until explicit Run.", "owned-effects script-trace lifecycle"),
        ("Corrupt/future workspace bytes remain at original exact hash after failed load/normal close; explicit recovery backup matches before overwrite.", "file-fault lifecycle")],
    "F22": [
        ("History contains one original statement source/outcome per success/failure/cancel with captured document/profile IDs; fixed 1001-entry/31-day inputs enforce 1000/30-day limits.", "source-state fixed-inputs script-trace"),
        ("Disable, Clear History and Clear Drafts exact expected DTO deltas survive normal restart; unrelated profiles/settings/credentials remain equal.", "source-state lifecycle"),
        ("Reopen original history entry creates source-only document with exact known source hash and zero physical connections/execute/effect delta.", "source-state script-trace owned-effects")],
    "F23": [
        ("Independent synthetic DDL catalog yields exact distinct object/detail identity sets for tables/views/functions/procedure/trigger/columns/keys/indexes/constraints.", "server-browse"),
        ("One bounded owned catalog fault then Retry loads exact expected set once with same profile/database owner.", "fault-boundary server-browse"),
        ("After fixed owned object removal and Refresh, removed identity absent and other profile's distinct set unchanged; late original reply refused.", "owned-effects server-browse fault-boundary")],
    "F24": [
        ("Unexpanded target is found by independent catalog search request, with expected quoted identity set and a positive server request delta despite zero prior expansion.", "server-browse script-trace"),
        ("Search clear/change and profile switch under delayed reply retain newest exact match IDs; old profile/request/source cannot publish matches.", "server-browse fault-boundary")],
    "F25": [
        ("Fixed table/view/routine capability matrix enables only appropriate actions; native pointer/context-keyboard entry points agree.", "server-browse native-manual"),
        ("Independent fixed identifier fixtures with spaces/emoji/embedded quote use PostgreSQL double quotes or MySQL backticks and exact generated source hash.", "fixed-inputs source-state"),
        ("Generate SELECT creates source-only original document with expected source hash, zero new connections/execute/effect counts.", "source-state script-trace owned-effects"),
        ("Structure/Definition/Data detail metadata matches independent original object identity/type/DDL digest, including profile/database capture.", "server-browse expected-metadata")],
    "F26": [
        ("For each 200-row page/sort/nine typed filters, compare actual original PK arrays to fixed physical readonly expected query; requests execute server-side, no client-only slice.", "server-browse fixed-inputs"),
        ("Equal sort values use full PK tie-breaks; concatenated page IDs have no duplicate/missing boundary keys, including composite (1,1),(1,2),(2,1).", "server-browse"),
        ("Dedicated table document retains exact profile/database/schema/table/result/snapshot identities across paging and stale replies.", "typed-grid source-state"),
        ("Invalid typed numeric/binary/filter input yields zero browse request/effect delta and original page/selection unchanged.", "server-browse script-trace")],
    "F27": [
        ("Native result columns match oracle columns exactly, retaining duplicate x ordinals, per-engine native types, PostgreSQL OIDs and Base64 payload encoding.", "expected-metadata typed-grid"),
        ("Native typed values and independent head rows equal null, empty, literal NULL, exact scale-18 numerics, AP8=/empty/AA== binary and combining/CRLF corpus.", "typed-grid expected-metadata"),
        ("Over-1000-row and over-8MiB cases disclose exact full/displayed counts/truncation; 1000 retained rows never imply full export count.", "fixed-inputs expected-metadata script-trace"),
        ("Later result failure preserves prior exact ordered sets and partial-error/transaction terminal ownership instead of replacing them with current tab results.", "fault-boundary expected-metadata script-trace")],
    "F28": [
        ("Cell/rectangle/sparse-row selections produce exact independently selected original row/column arrays in source order, including noncontiguous rows.", "clipboard typed-grid native-manual"),
        ("Native typed clipboard JSON equals independent schema/ordinals/null/Base64 selected subset, never flattened duplicate-name object keys.", "clipboard expected-metadata"),
        ("Native TSV bytes equal independent selected cells with explicit SQL NULL marker; embedded tabs/CRLF/quotes escaped and marker collision handled.", "clipboard"),
        ("Neither typed JSON nor TSV includes visual row-number column; compare exact original column count/ordinals.", "clipboard expected-metadata")],
    "F29": [
        ("Original 1000x32 grid resized column widths and original selected row IDs persist across switch/theme changes without new result identity.", "typed-grid fixed-inputs native-manual"),
        ("Native horizontal scroll reaches last original column; realized row slice stays bounded and offscreen action realizes correct original row.", "typed-grid native-manual"),
        ("Visual row-number header remains fixed while data columns scroll; native positions match original row ordinals without becoming selection data.", "typed-grid native-manual"),
        ("Real keyboard focus/selection is visibly retained across scroll/DPI/theme and announced by target native accessibility.", "native-manual typed-grid")],
    "F30": [
        ("Inspector exact known 1MiB text hash and binary byte count/Base64 match fixture with documented bounded rendering, never a copied UI value oracle.", "typed-grid fixed-inputs"),
        ("Inspector distinguishes SQL NULL, empty, text NULL, multiline and binary using exact semantic kind/value/description, not just text hash.", "typed-grid"),
        ("Adapter capability matrix governs actual edit actions/reasons for PK/generated/view/noPK/restricted/nontransactional objects; no mutation before Apply.", "typed-grid server-browse")],
    "F31": [
        ("Typed editor capture preserves exact text/numeric/Base64 states; observer sees only expected values after original Preview/Apply.", "typed-grid expected-metadata"),
        ("Separate fresh cases assign null/empty/literal NULL/default; physical values are null, empty, NULL, fixture default with generated lengths null/0/4/15.", "typed-grid owned-effects expected-metadata"),
        ("Generated/noPK/view/restricted/MyISAM cells refuse staging or Apply with fixed capability reason and exact unchanged observer snapshot.", "typed-grid server-browse")],
    "F32": [
        ("Mixed stage operations leave independent values-head/composite/count snapshots unchanged until explicit Apply.", "typed-grid expected-metadata"),
        ("Original row snapshots and typed staged delta/counts exactly match insert/update/delete fixture; Columns and markers track captured ordinal ownership.", "typed-grid source-state"),
        ("Edit-back-to-original, delete newly inserted row and Discard leave zero draft deltas; original selected IDs and observer rows unchanged.", "typed-grid source-state")],
    "F33": [
        ("Preview received typed batch hash equals original immutable staged capture, including null/default/exact numeric/binary values and PK/original snapshot hashes.", "typed-grid script-trace"),
        ("Generated parameterized mutation SQL hash originates in exact helper adapter preview; GUI command trace contains typed request only and no frontend mutation SQL construction.", "script-trace"),
        ("Edit/context change under delayed preview invalidates original grant; Apply disabled/refused, observer unchanged, old success cannot authorize a new revision.", "fault-boundary typed-grid")],
    "F34": [
        ("Apply's physical backend ID differs from SQL/service IDs and starts idle; exact fixed observer delta occurs once.", "session-observer owned-effects"),
        ("Original SQL tab backend/transaction/temp setting remains unchanged and its uncommitted receipt is still invisible to independent observer.", "session-observer"),
        ("Locked original snapshot rejects edit/navigation/profile changes; stale completion for another result/revision cannot unlock/replace or publish success.", "fault-boundary typed-grid")],
    "F35": [
        ("Fresh success batch yields every expected insert/update/delete and counts together; constraint/deadlock/cancel batch leaves entire original independent snapshot unchanged.", "owned-effects fault-boundary expected-metadata"),
        ("Observer modifies a fixed original nonPK value/constraint before Apply; full-original compare conflict refuses with no partial writes and original draft retained.", "owned-effects fault-boundary typed-grid"),
        ("Known failed/cancelled terminal keeps original typed draft batch/hash for explicit recovery; no automatic rerun or loss of original originals.", "typed-grid fault-boundary"),
        ("Only explicit Reload replaces baseline/draft/result identity with independently observed current rows; stale success cannot simulate reload.", "typed-grid expected-metadata")],
    "F36": [
        ("Lose only real SQL/Apply commit acknowledgment after physical observer proves committed receipt=1; native state is unknown until explicit verification decision.", "fault-boundary owned-effects"),
        ("Attempt retry/reapply/repeated close before verification; receipt remains exactly 1, never 0/2, and no second mutation execute trace occurs.", "owned-effects script-trace fault-boundary"),
        ("Close retains unknown original operation and recovery controls; explicit independent verify then Discard/Reload resolves to committed snapshot with no blind rerun.", "fault-boundary typed-grid lifecycle")],
    "F37": [
        ("Loaded exact JSON/CSV hashes match original captured 1000 rows/metadata with full rowCount1205/1005 and truncated=true after tab/result replacement.", "fixed-inputs expected-metadata typed-grid"),
        ("Loaded export has zero helper execute/effect delta, even after result replacement; physical count alone cannot prove absence of readonly SQL.", "script-trace owned-effects"),
        ("Cancel/locked/changed destination preserves captured original file inode/hash and never publishes partial output or reruns query.", "file-fault script-trace")],
    "F38": [
        ("Loaded JSON exact independently serialized bytes preserve ordered duplicate columns/metadata/typed arrays/Unicode/CRLF/exact strings for each engine.", "fixed-inputs expected-metadata"),
        ("Default backslash-N marker collides with fixed row5 and refuses; explicit <DBEER-SQL-NULL> yields exact independently encoded CSV bytes/records.", "file-fault fixed-inputs"),
        ("Parse exact output to typed independent row arrays; SQL null/empty/text NULL/binary remain distinct without converting numeric strings to floating point.", "expected-metadata")],
    "F39": [
        ("Full exact JSON/CSV hashes contain 1205 PostgreSQL/1005 MySQL rows, physical values-count agrees; independently sorted tail avoids MySQL auto-ID order assumption.", "fixed-inputs expected-metadata"),
        ("Fixed Run-to-File routine increments dedicated server counter exactly once and emits full rows; receipt=1 after success/late-stop/publication failure, never inferred from file count.", "owned-effects script-trace fault-boundary"),
        ("Fixed routine JSON preserves all expected data/status set metadata/order; CSV rejects multiple sets without destination publication.", "owned-effects expected-metadata file-fault"),
        ("Stop/first-error/middle-error/locked replacement leaves prior destination identity/hash intact; server receipt states match exact completed statements and no partial file publishes.", "owned-effects file-fault fault-boundary")],
    "F40": [
        ("Separate LSP exact process/pipe receives bounded fragmented/coalesced Content-Length cases; DB helper connection/execute counters stay zero offline.", "language-oracle helper-lifetime"),
        ("Sanitized inherited LSP environment/argv audit excludes synthetic DB secret hashes; protocol frames/source never enter diagnostics.", "language-oracle"),
        ("Overflow/truncation/timeout/death/restart cases leave exact editor source/caret usable and explicit SQL Run still reaches original DB session once.", "language-oracle text-range helper-lifetime")],
    "F41": [
        ("Offline metadata request has zero DB/service counts; only explicit Connect creates original service session and loads metadata pages.", "session-observer language-oracle"),
        ("Expected complete fixture metadata ID set, foreign-key links and routine overload signatures equal independent catalog across every page.", "language-oracle server-browse"),
        ("Fixed add/remove/Refresh replaces original page cache; delayed former profile/generation reply cannot publish stale entries into current catalog.", "owned-effects language-oracle fault-boundary")],
    "F42": [
        ("For both dialects, every shared completion case has nonempty pinned Go oracle evidence and exact suggestion order/quote/insertion/UTF16 fuzzy spans; missing/zero cases refuse.", "language-oracle fixed-inputs text-range")],
    "F43": [
        ("Source fixture expected context enables popup in SQL, refuses literal/comment/invalid context; no hidden DB action offline.", "language-oracle fixed-inputs"),
        ("Real Tab/Return/Escape preserves original editor focus/caret/selection and no navigation is consumed outside original popup owner.", "native-manual text-range"),
        ("Accepted fixed quoted identifier source hash equals oracle and one native Undo restores exact before source without undoing an earlier edit.", "native-manual language-oracle text-range"),
        ("Under active real IME and delayed stale replies, original/new source hashes and revision stay untouched by completion; literal/comment replies never insert.", "native-manual fault-boundary text-range")],
    "F44": [
        ("Each shared signature case matches known function/overload/return type/active-parameter UTF16 spans, including nested/named/default/variadic/nonBMP.", "language-oracle fixed-inputs text-range"),
        ("Delayed help/diagnostic response for prior caret/source/profile cannot change current exact signature/diagnostic capture.", "language-oracle fault-boundary"),
        ("Offline built-in help has zero DB connection/metadata/execute delta; native theme/DPI renders actual intended independent editor palette.", "language-oracle script-trace native-manual")],
    "F45": [
        ("Toolbar/menu/native keyboard commands capture same original document/source/range/profile/query hash and execute exactly once despite active-tab switch.", "script-trace native-manual fault-boundary"),
        ("Editing/Complete SQL/protected native shortcuts retain expected text/clipboard behavior and produce zero execution request delta outside allowed context.", "native-manual script-trace"),
        ("Editor/grid/chooser/modal/busy context matrix exposes identical permitted command set at menu/toolbar/keyboard; stale command rejects without mutation.", "native-manual script-trace")],
    "F46": [
        ("Native Clear yields exact override query.runCurrent binding.state=unbound; restart retains it and Run default no longer dispatches.", "settings-oracle lifecycle native-manual"),
        ("Duplicate/protected/Complete SQL key attempts preserve exact previous preferences hash and show fixed validation; no accidental dispatch.", "settings-oracle native-manual"),
        ("Corrupt/future shortcut file stays exact original bytes during readonly fallback; explicit Recover Defaults writes exact backup before latest-value reset.", "file-fault settings-oracle lifecycle"),
        ("After native rebind/reset, menu/toolbar labels and actual native command match same preferences including nonLatin/AltGr; IME/dead/Unknown/repeat never records.", "settings-oracle native-manual")],
    "F47": [
        ("Exact independent appearance DTO retains chosen application/editor IDs across restart; missing IDs preserve stored strings but resolve safe fallback.", "settings-oracle lifecycle"),
        ("Real OS light/dark change alters only System/Follow resolved palette, not explicit selected ID, saved bytes, source/query/session or independent editor choice.", "settings-oracle native-manual"),
        ("All actual screens/popups resolve the chosen app/editor palette with independent expected color/alpha/scope roles and observable readable native rendering.", "settings-oracle native-manual")],
    "F48": [
        ("Every shared JSONC/include/TextMate/binaryPlist/JetBrains normalized expected color/font/scope/alpha precedence matches pinned fixture, independent of imported UI output.", "settings-oracle fixed-inputs"),
        ("Explicit import/review/commit persists normalized custom theme; remove source under owned receipt then normal restart still loads exact colors; remove custom only after successful ordered commit.", "settings-oracle file-fault lifecycle native-manual"),
        ("Traversal/symlink/cycle/remote/entity/oversize inputs yield fixed parser errors and zero library change; corrupt/future bytes require explicit recovery backup.", "settings-oracle file-fault fixed-inputs"),
        ("Exact bundled theme source/license/notice digest inventory is included in the manifest, not merely a UI link or inferred package filename.", "package-evidence")],
    "F49": [
        ("During original query and edit, app/editor switch preserves exact original editor entity/text/Undo/selection/scroll, result IDs/selection and operation token; live palette changes expected roles only.", "settings-oracle text-range typed-grid native-manual"),
        ("Actual Windows/Wayland/X11 light controls, focus/hover/selection/text/icons remain visible/readable under native screen-reader/highContrast/DPI observations.", "native-manual settings-oracle")],
    "F50": [
        ("Real native keyboard/IME/nonLatin/AltGr/file paths preserve fixed emoji/combining/CRLF source hashes and standard dialog/window behavior.", "native-manual fixed-inputs"),
        ("Native Open/Save/CA and clipboard roundtrips compare exact independently known bytes/types; chooser cancel preserves original binding/destination.", "native-manual clipboard file-fault"),
        ("Real fractional/mixed-monitor DPI/window changes preserve visible focus/caret/selection and readable geometry on all three supported targets.", "native-manual")],
    "F51": [
        ("Fresh UI-created UUID reserved absent, then actual app nonempty/empty/keep/update/delete yields exact expected hashes and no unrelated lookup.", "credential-update native-manual"),
        ("Locked/unavailable/rollback-failure cases report fixed errors boundedly; absence stays unproven and no success/cleanup ownership is invented.", "credential-update native-manual"),
        ("Conditional cleanup only after normal GUI exit rechecks expected hash; foreign replacement preserved; metadata allow-list has no plaintext fallback and prior owned password survives failure.", "credential-update source-state lifecycle")],
    "F52": [
        ("Narrator or Orca actual keyboard navigation announces expected editor/grid/inspector/menu/Settings/dialog names/roles/kinds/actions/focus with original stable identity.", "native-manual typed-grid"),
        ("Actual keyboard reaches virtualized original row/column and safe modal Cancel default; visual/native position agrees with source, NULL/binary semantics announced.", "native-manual typed-grid text-range"),
        ("Require explicit supported-target human observation pinned to exact artifact/session; no headless/render/source/native-node-count evidence can fulfill this assertion.", "native-manual matrix-join")],
    "F53": [
        ("Actual GUI-spawned sibling helper exact executable hash/build identity/capturedExportV1 matches artifact and native Windows has no console window.", "helper-lifetime native-manual package-evidence"),
        ("Held ACK saturation plus real Stop yields bounded queued frames/progress and original terminal order/count with physical server cancellation.", "helper-lifetime fault-boundary script-trace"),
        ("Owned helper death yields disconnected versus unknown according to fixed transaction phase; independent observer receipt proves no fabricated rollback.", "helper-lifetime fault-boundary owned-effects"),
        ("Fault targets only retained exact handle/hash/creation time; registered unrelated sentinel process/file identities remain unchanged through cleanup.", "helper-lifetime package-evidence")],
    "F54": [
        ("Actual trusted compatible prototype/candidate retains original opaque IDs and exact reserved credential hashes under same canonical data owner; concurrent old/new safely refuses.", "package-evidence credential-update lifecycle"),
        ("Exact GUI/helper embedded identity, build-info and hello metadata match canonical manifest, PE/ELF architecture and actual Windows icon/taskbar/version resources.", "package-evidence native-manual"),
        ("Separately completed native macOS SwiftUI/AppKit build/tests/signing/package route uses existing identity and original release conventions; GPUI Mac cannot substitute.", "matrix-join")],
    "F55": [
        ("Actual clean standard-user Windows11/Ubuntu24 x64 Wayland/X11 launches extracted candidate without Go/Rust using documented GPU/runtime/store dependencies; native warnings/provenance recorded.", "package-evidence native-manual"),
        ("Archive/whole-file manifest exact helper/version/capability and complete dependency/theme/license notices validate against independent pinned package inputs.", "package-evidence"),
        ("Old release archive path/size/hash receipts are unchanged and verified complete-folder manual update publishes only a new owned candidate folder.", "package-evidence file-fault")],
    "F56": [
        ("Actual previous→candidate normal close/update compares populated exact UUID/order/policy/TLS/credentials/document/history/appearance/library/shortcut hashes.", "package-evidence source-state credential-update lifecycle"),
        ("Ordinary candidate restart restores source-only original documents with zero product connections and execute/effect deltas until explicit Connect/Run.", "lifecycle source-state script-trace owned-effects"),
        ("Previous/previous, previous/candidate, candidate/previous, candidate/candidate exact cooperating lock attempts refuse while owner alive; all canonical state bytes remain equal.", "package-evidence lifecycle"),
        ("Remove only original owned integration/file receipts after normal close; unrelated sentinel file/process identities unchanged and private app data/credentials remain unless explicitly removed.", "package-evidence file-fault lifecycle")],
    "F57": [
        ("Require all 171 frozen target cells with every assertion and mandatory proof kind, both engines plus all required versions/TLS/faults, exact prior/candidate builds/session and nonempty completed summaries.", "matrix-join"),
        ("Reject headless/container/Server-as-Windows11, zero-case, missing manual observation, missing engine or incomplete cleanup as native pass.", "matrix-join native-manual"),
        ("Join actual completed required SwiftUI/AppKit/Go regression summaries with exact native artifacts; skipped/unrun Mac route keeps parity open.", "matrix-join")],
}

DATA_REFS = {
    "profiles": ["protocol/fixtures/profile-transfer", "prototypes/gpui/fixtures/installed-acceptance/recipes/input-corpus.json"],
    "editor": ["protocol/fixtures/sql-execution/v1.json", "prototypes/gpui/fixtures/installed-acceptance/recipes/input-corpus.json"],
    "language": ["protocol/fixtures/completion-matches.json", "protocol/fixtures/signature-help.json", "prototypes/gpui/fixtures/signature-help/cases.json"],
    "theme": ["protocol/fixtures/gpui-theme-parity/cases.json", "prototypes/gpui/fixtures/settings-appearance/selections.json"],
    "commands": ["prototypes/gpui/fixtures/shortcut-settings/capture-safety.json", "prototypes/gpui/fixtures/shortcuts/preferences-v1.json"],
}


def build(catalog, fragments):
    rows = catalog.get("scenarios", [])
    expected = {"F%02d" % n for n in range(1, 58)}
    if len(rows) != 57 or {row["feature"] for row in rows} != expected or set(CHECKS) != expected:
        raise ValueError("Exact 57 frozen scenarios are required; zero/missing cases refuse.")
    prepared = []
    for row in rows:
        feature = row["feature"]
        engines = row.get("engines")
        if (not isinstance(engines, list) or not engines
                or any(not isinstance(engine, str) or not engine for engine in engines)):
            raise ValueError("Nonempty exact engine requirements are mandatory.")
        if "independent-physical-database-observer" in row["proofKinds"] and not all(
                any(engine.startswith(family) for engine in engines) for family in ("postgresql", "mysql")):
            raise ValueError("Both database families must remain required.")
        assertions = [("%s-S%02d-A%02d" % (feature, si, ai), text)
                      for si, step in enumerate(row["procedure"], 1)
                      for ai, text in enumerate(step["assertions"], 1)]
        checks = CHECKS[feature]
        if not assertions or len(assertions) != len(checks):
            raise ValueError("Frozen procedure assertion count changed; explicit review required.")
        planned = []
        for (identifier, text), (check, requirements) in zip(assertions, checks):
            needed = sorted(set(requirements.split()) | {"native-bindings"})
            if not check or any(item not in REQUIREMENTS for item in needed):
                raise ValueError("Missing concrete independent check or integration operation.")
            planned.append({"id": identifier, "frozenAssertion": text,
                            "independentExpectedOutcome": check, "requires": needed,
                            "status": "source-plan-only", "passed": False,
                            "fragments": [f["id"] for f in fragments["fragments"] if identifier in f["addresses"]]})
        prepared.append({"feature": feature, "scenarioId": row["id"],
                         "procedure": row["procedure"], "requiredEngines": row["engines"],
                         "mandatoryProofKinds": row["proofKinds"],
                         "manualRequiredByFrozenCatalog": row["manualRequired"],
                         "assertions": planned,
                         "nativeCells": {target: "not-run" for target in
                                         ("windows11-x64", "ubuntu2404-x64-wayland", "ubuntu2404-x64-x11")}})
    count = sum(len(row["assertions"]) for row in prepared)
    return {"schemaVersion": 1, "kind": "installed-acceptance-recipe-coverage",
            "registrySha256": catalog["registrySha256"], "nativeObserved": False,
            "selectorIntegrationReviewed": False, "runtimeExecuted": False,
            "scenarioCount": 57, "assertionCount": count, "nativeCellCount": 171,
            "status": "source-plan-only-task32-open", "requirements": REQUIREMENTS,
            "sharedExpectedData": DATA_REFS,
            "independentExpectedManifest": "expected-values.json",
            "additionalEffectSetup": "effects/plan.json",
            "scenarios": prepared}


def load_strict(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate fixture key.")
            result[key] = value
        return result
    return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique)
