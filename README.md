<p align="center">
  <img src="Assistant/Assistant/Assets.xcassets/AppIcon.appiconset/icon-128.png" alt="Assistant" width="128">
</p>

<h1 align="center">Assistant for macOS</h1>

A native macOS app for [Assistant](https://github.com/rb81/assistant), the
self-hosted AI assistant. Chat, check scheduled reminders, and manage your
connection without keeping a terminal open.

## Features

- **Chats:** searchable conversations, Markdown and code, attachments, audio
  playback, and optional tool activity.
- **Reminders:** check the schedule and read past results. Ask about a run in
  a separate chat rather than replying to the scheduled task.
- **Connection & Support:** open from the connection status in the sidebar for
  service status, diagnostics, and workspace files.
- **Settings:** open the gear at the bottom of the sidebar. Browse everyday
  settings in one scrollable list or jump to a field by searching. Drafts
  survive navigation, with reviewed saves and explicit activation.
- **Live updates:** resumable updates over the existing SSH tunnel, with polling
  fallback and optional private macOS notifications while the app is running.
- **Local or remote:** connect to an installation on your Mac or securely over SSH.

## Download

**Signed and notarized builds will be published on the
[Releases page](https://github.com/rb81/assistant-client/releases).**
Until a release is available, [build from source](docs/development.md).

Requires **macOS 14 or later** and a running
[Assistant server](https://github.com/rb81/assistant#install).
The app manages that server; it does not bundle one. A remote connection needs
no Docker, Python, Rust, or Node installation on your Mac.

## Connect

For a server on this Mac, choose **Installation on this Mac**. The server
installer must have registered `~/.local/bin/assistant`.

For a remote server:

1. Establish SSH trust and key/agent authentication in Terminal:
   `ssh your-server-alias`.
2. In the app, choose **Connect**, enter that alias or `user@host`, and confirm.

The app uses your SSH configuration and an authenticated loopback tunnel.
Unknown or changed host keys are rejected; there is no password or host-trust
wizard. On macOS 15+, allow **Assistant** under System Settings > Privacy &
Security > Local Network when connecting to a LAN server.

Closing the app closes its tunnel, **not the server or running tasks**.

## Privacy and safety

API credentials stay in session memory. Saved profiles contain connection
details, not tokens. Conversation bodies and tool details are cached locally,
per installation; remove them using **Settings > General > Clear conversation cache**. This cache
is not separately encrypted, so protect your macOS account and disk.

Attachments stay in memory unless explicitly downloaded. Configuration changes
require review, destructive actions require confirmation, and uncertain writes
are never automatically replayed. Server-side permissions and approval checks
still apply.

All channels are visible initially. The channel filter is remembered per
installation; “Assistant client” does not mean “this Mac.” Continuing an email
or Telegram conversation requires confirmation that replies will use this client.
Notifications never include message bodies and require explicit permission.
They cannot arrive after quitting the app.

Read the [server security guide](https://github.com/rb81/assistant/blob/main/docs/security.md)
before connecting sensitive accounts or data.

## Development

See the [build and contribution guide](docs/development.md) for Xcode setup,
local signing, tests, architecture, and release checks. The app uses the shared
[Management API](https://github.com/rb81/assistant/blob/main/docs/building-clients.md);
server operations belong on the server, not in this UI.

[Apache 2.0 license](LICENSE), the same license as Assistant.
