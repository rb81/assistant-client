# Build and contribute

## Build

Use Xcode with the macOS SDK on a Mac. The app targets macOS 14+ and has no
third-party Swift dependencies.

From the repository root:

```sh
cp -R Assistant/Assistant.xcodeproj.example Assistant/Assistant.xcodeproj
cp Assistant/Config/Identifiers.example.xcconfig Assistant/Config/Identifiers.xcconfig
open Assistant/Assistant.xcodeproj
```

Do not overwrite an existing local project or identifier file. Select the
**Assistant** scheme and **My Mac**, then Build/Run. The initial template uses
placeholder identifiers and ad-hoc signing; no Apple Developer Team ID is needed.
The app performs no network activity until you connect.

The example project uses the format produced by its Xcode tooling. Use a
compatible Xcode version rather than manually converting its project format.

### Local signing

Keep working `.xcodeproj` files, personal identifiers, signing teams, and user
state out of Git. Commit source, tests, resources, and the placeholder
`.xcodeproj.example` when targets or build settings change. Never copy
`xcuserdata` into the example.

Set app/test bundle identifiers and your development team in the local project.
Alternatively, select `Config/Base.xcconfig` as the base configuration: it
optionally includes the ignored `Identifiers.xcconfig`. Remove overriding target
values for settings supplied by that configuration.

Use an Apple-issued development identity for reliable Local Network permission
tracking. Ad-hoc signing is sufficient for isolated tests but may not retain
permissions across builds.

Keep these settings in both local projects and the public template:

| Setting | Reason |
|---|---|
| `ENABLE_DEBUG_DYLIB = NO` | Keep the main executable's identity unambiguous. |
| `OTHER_LDFLAGS` includes `-Wl,-random_uuid` | Prevent different bundle IDs sharing an executable UUID and mixed network permissions. |
| Release testability disabled | Keep library validation enabled in distributed builds. |

Link UUIDs intentionally vary, so repeated builds are not bit-for-bit identical.
See Apple's [TN3178](https://developer.apple.com/documentation/technotes/tn3178-checking-for-and-resolving-build-uuid-problems)
and [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Tests

Use **Product > Test** for unit tests and disconnected/connected UI tests.
Inject `ManagementAPI` fixtures; do not use production credentials or SSH hosts.
The explicit Debug-only connected fixture covers navigation, sending, code
copying, reviewed source-free settings saves, local notification controls, and safe deletion in
light/dark appearances. Screenshots remain in the test result bundle.

App-target Canvas previews are unavailable with debug-dylib mode disabled.
Use the running app and UI tests rather than re-enabling it. A future preview
framework/scheme must preserve the executable-identity safeguards.

Fixture tests do not establish live SSH recovery or production release readiness.
Verify discovery, tunnel cleanup, authenticated reads/writes, server restarts,
sleep/wake, polling recovery, and partial transfers against a disposable server.

Copy controls use AppKit target/action and a full 28-point hit area, independent
of prose selection. Hosted tests cover center/edge hit-testing, first-click
acceptance, and copying the current complete source to a unique test pasteboard
in both appearances. These do not replace the end-to-end UI copy/paste test.

## Architecture

| Directory under `Assistant/` | Responsibility |
|---|---|
| `Assistant/Core/` | Typed contracts, bounded HTTP, owned OpenSSH processes, state and polling |
| `Assistant/Features/` | Screens, presentation, and drafts |
| `Assistant/DesignSystem/` | Shared appearance, native Markdown and JSON rendering |
| `AssistantTests/`, `AssistantUITests/` | Isolated unit and UI coverage |
| `Config/` | Public signing template and ignored local values |

All management operations use the shared
[Management API](https://github.com/rb81/assistant/blob/main/docs/management-api.md).
SSH runs only the fixed installed discovery launcher and owns the loopback tunnel;
it is not a shell-command management interface. Domain validation and execution
stay on the server. Keep UI state on the main actor and transport ownership isolated.

### Compatibility and state

Discovery returns protocol version **1**; authenticated `/v2/health` returns
Management API version **2**. Verify installation identity and required
capabilities after connecting. Missing capabilities require an explicit
unsupported-feature message, not a fabricated empty result. There is no
published server/client release compatibility matrix yet.

Configuration drafts require revision-bound previews and confirmation.
HTTP 202 means a mutation was accepted, not completed: poll its operation ID.
Retain uncertain submission metadata, never automatically replay writes or
persist secret request bodies. See the
[client protocol guide](https://github.com/rb81/assistant/blob/main/docs/building-clients.md).

Conversation drafts and API tokens stay in session memory. Loaded transcripts
and tool details are cached in preferences per verified installation identity
until **Clear conversation cache**. Downloads have a 64 MiB per-file limit.
Workspace uploads are scanner-gated and limited to 1 MiB.
Closing the client never stops services.

Chat and reminder unread markers are local to this Mac, installation-scoped,
persisted separately, and independent of delivery acknowledgments.
Service inventories are cached per installation and refreshed every ten seconds
while Connections is open; cached statuses are not proof of current health.
Transient inventory failures get three read attempts (250/500 ms backoff)
before a warning; authentication and validation failures are not retried.
Writes are never automatically retried.
Attachment downloads require the server to return a current SHA-256 digest,
including for project files whose tracking metadata has no digest.

Negotiate `tasks.snapshot` and `events.stream` for pooled newest-page snapshots
and resumable SSE invalidations over the existing SSH tunnel. Coalesce event
bursts; keep delivery polling for availability leases, acknowledgments, and
fallback. Notification metadata is installation-scoped, deduplicated and bounded;
message bodies are excluded. Native alerts require opt-in and do not work after
the app quits.

Settings require `configuration.structured`, load a source-free catalog, then
effective values by owning page. Standing instructions load separately.
Never restore a raw-source fallback for older servers. Local App preferences
do not enter server drafts. Pending/uncertain activation is separate from dirty
state and survives relaunch.

Negotiate `configuration.activation` for server-backed saved-change tracking.
Its review contains redacted current saved values, not a live-container diff.
Apply the exact reviewed revision using `service.lifecycle`; stale reviews must
be reloaded. Pending activation has a global banner and its own review sheet,
separate from unsaved edits and generic technical request confirmations.
Missing receipts remain unresolved; inspecting settings alone never resolves a
lost activation request. Known pending actions block Apply, and an unconfirmed
action requires explicit acknowledgment before another application attempt.

The server owns Basic/Advanced membership: credentials and ordinary connection
setup are Basic; timeouts, polling intervals and other tuning are Advanced.
Text-to-speech progressively reveals model/voice setup when enabled, using
advertised cached voices when available without replacing an unsupported saved
voice. Model tools and speech share one budget page. Global OpenRouter ZDR and
speech-specific ZDR merge into one `provider.zdr` flag. Calendar default choices
include primary/numbered accounts with complete saved OAuth credentials,
not default calendar IDs or verified connectivity. Choice labels are presentation
only; for example, **Email & Telegram** still submits `both`.

Settings stay mounted after first opening, including drafts when visiting other
destinations. Disconnecting still requires saving or explicitly discarding a draft.
The complete menu prefetches at connection and persists per verified installation;
the first uncached load shows one loading state, not partial static entries.
The disk cache whitelists group descriptors and field navigation metadata:
effective values, defaults, help bodies, credentials, instructions and source are
excluded. Cached descriptors never initialize an editable form. Unchanged menus
are retained; same-revision metadata updates preserve loaded values and drafts.
Sidebar, chat, reminder, settings and Data divider widths use stable native
split-view autosave names. Settings navigation defaults to 270 points.
Source-free reads and side-effect-free
skill queries coalesce in flight. Ordinary reads use a bounded, 60-second session cache;
reopening Settings rechecks expired catalog metadata without clearing drafts.
Skills prefetch at connection, retain browsing state, and cache pages/details for
15 minutes in memory. Unrelated settings/inventory invalidations preserve that
cache; explicit skill refreshes, skill mutations, and disconnects invalidate it.
Permission requests, update notices, and operation receipts live in the
global Activity sheet. Negotiate `operations.lookup` to recover missing receipts
by their persisted submission key; missing/expired results never authorize replay.

OpenRouter's public HTTPS model catalog is cached separately for full/ZDR policy.
The weekly-refresh switch and manual refresh are local preferences, not server
configuration. No installation or provider credentials enter discovery. Public
eligibility cannot guarantee account-specific access. The server independently
enforces `provider.zdr=true` on OpenRouter requests when global ZDR is enabled.

Remote Markdown uses native text views: HTML/scripts and remote images are not
executed or loaded. Diagnostics remain selectable technical details, not the
primary interface.

Data uses a split file browser and native preview pane: safe Markdown text,
inert UTF-8/UTF-16 text/code, ImageIO images, PDFKit, Quick Look for Office/fonts,
and AVKit for contained audio/video files. Data alone uses the full available width.
Previews verify the complete bounded download before rendering: text/Markdown 2 MiB,
images/PDF/Quick Look 16 MiB, media 64 MiB. Image decoding runs off the UI actor,
rejects images over 80 megapixels, and downsamples the first frame to at most
4096 pixels per edge before fit/zoom display. HTML and SVG are source-only.
Unsupported formats/codecs have explicit errors
and an independent Download action; playlists are not previewed. No autoplay.
Selection changes, navigation, and normal shutdown stop playback and clear
preview resources. Quick Look/media files use unique OS temporary directories with
0700 permissions and 0600 files; cleanup also covers cancelled/stale results.
Abnormal process termination can leave these files for OS temporary-file cleanup.

Disclosure headings are full-width keyboard-accessible buttons throughout the
app and its sheets. Tool-detail derivation and JSON formatting run off the UI
actor with immediate loading feedback, cancellation/stale-result protection, and
a bounded native selectable text viewport rather than an unbounded text layout.
Sidebar and Settings footers share a fixed height; idle status has a real icon
and vertically centered text, with a second line only for actual feedback.

## Design and assets

The palette comes from the icon's sampled sky blue (`#5D91B8`), amber glow
(`#FAC373`), cream shell (`#DDB289`), and dark face (`#4C3930`).
Blue controls and cool neutral surfaces keep the warm brand accents restrained.
Light/dark text and control pairs meet at least 4.5:1 contrast.
The UI uses the macOS system font, with system monospace for
diagnostic output. The asset catalog's `AppIcon.appiconset` contains the
1024-pixel icon master and the smaller macOS sizes derived from it.

## Release checklist

Publish direct downloads through
[GitHub Releases](https://github.com/rb81/assistant-client/releases) only after:

- Developer ID signing, Hardened Runtime, and notarization.
- Release testability disabled and library validation enabled.
- Fresh-Mac installation and Intel/Apple-silicon acceptance.
- Live local/SSH connection, mutation recovery, and upgrade compatibility checks.

The app disables App Sandbox to use system SSH configuration and agent access;
it is not configured for App Store submission. No automatic updater is included.
Review an update mechanism separately before adding dependencies.
