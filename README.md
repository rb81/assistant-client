<p align="center">
  <img src="Assistant/Assistant/Assets.xcassets/AppIcon.appiconset/icon-128.png" alt="Assistant" width="128">
</p>

<h1 align="center">Assistant for macOS</h1>

A native macOS app for [Assistant](https://github.com/rb81/assistant), the
self-hosted AI assistant. Chat, follow tool activity, and manage your server
without keeping a terminal open.

## Features

- **Chats:** searchable conversations, Markdown and code, attachments, audio
  playback, and inline tool activity.
- **Server Health:** service status, logs, start/stop controls, and saved-setting
  activation.
- **Data:** browse and transfer workspace files, with reviewed deletion.
- **Settings:** configure your assistant and integrations, review changes, and
  edit source configuration with retained backups.
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
per installation; remove them using **Settings > Clear chat cache**. This cache
is not separately encrypted, so protect your macOS account and disk.

Attachments stay in memory unless explicitly downloaded. Configuration changes
require review, destructive actions require confirmation, and uncertain writes
are never automatically replayed. Server-side permissions and approval checks
still apply.

Read the [server security guide](https://github.com/rb81/assistant/blob/main/docs/security.md)
before connecting sensitive accounts or data.

## Development

See the [build and contribution guide](docs/development.md) for Xcode setup,
local signing, tests, architecture, and release checks. The app uses the shared
[Management API](https://github.com/rb81/assistant/blob/main/docs/building-clients.md);
server operations belong on the server, not in this UI.

[Apache 2.0 license](LICENSE), the same license as Assistant.
