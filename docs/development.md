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
copying, reviewed settings saves, YAML editor access, and safe deletion in
light/dark appearances. Screenshots remain in the test result bundle.

App-target Canvas previews are unavailable with debug-dylib mode disabled.
Use the running app and UI tests rather than re-enabling it. A future preview
framework/scheme must preserve the executable-identity safeguards.

Fixture tests do not establish live SSH recovery or production release readiness.
Verify discovery, tunnel cleanup, authenticated reads/writes, server restarts,
sleep/wake, polling recovery, and partial transfers against a disposable server.

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
until **Clear chat cache**. Attachments are memory-only unless downloaded, with a
64 MiB per-file limit. Workspace uploads are scanner-gated and limited to 1 MiB.
Closing the client never stops services.

Unread markers are local to this Mac and separate from delivery acknowledgments.
Service inventories are cached per installation and refreshed every ten seconds
while Server Health is open; cached statuses are not proof of current health.
Attachment downloads require the server to return a current SHA-256 digest,
including for project files whose tracking metadata has no digest.

Remote Markdown uses native text views: HTML/scripts and remote images are not
executed or loaded. Diagnostics remain selectable technical details, not the
primary interface.

## Design and assets

Ink & Copper assets supply light/dark colors. UI text uses system fonts.
Terminal output uses `JetBrainsMonoNF-Regular` if installed, otherwise reports a
system monospace fallback. The app does not download fonts.

JetBrains Mono Nerd Font is optional and not vendored; redistribution requires
its upstream and patched icon-license notices. The icon source is
`Assistant/Assistant/Resources/AssistantMark.svg`; exported PNG sizes are in the asset catalog.

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
