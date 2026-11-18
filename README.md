<p align="center">
  <img src="Assistant/Assistant/Assets.xcassets/AppIcon.appiconset/icon-1024.png" alt="Assistant" width="240">
</p>

<h1 align="center">Assistant for macOS</h1>

A native macOS app for [Assistant](https://github.com/rb81/assistant), the
self-hosted AI assistant. Chat, check scheduled reminders, and manage your
connection without keeping a terminal open.

## Features

| Feature | What it does |
|---|---|
| **Chats** | Search conversations, read Markdown and code, open attachments, play audio, and inspect tool activity. |
| **Reminders** | Check schedules and past results. Start a new chat to ask about a scheduled run. |
| **Connection & Support** | Select the connection status in the sidebar for service health, diagnostics, and workspace files. |
| **Settings** | Select the sidebar gear to browse or search settings. Drafts survive navigation; review changes before saving and choose when to activate them. |
| **Live updates** | Receive resumable updates with polling fallback and optional macOS notifications while the app is open. |

## Download

| Item | Details |
|---|---|
| **Download** | Look for a signed, notarized build on [GitHub Releases](https://github.com/rb81/assistant-client/releases), or [build from source](docs/development.md). |
| **Requirements** | macOS 14 or later and a running [Assistant server](https://github.com/rb81/assistant#install). The app does not bundle the server. |
| **Remote connections** | No Docker, Python, Rust, or Node installation is needed on your Mac. |

## Connect

| Connection | Setup |
|---|---|
| **On this Mac** | Choose **Installation on this Mac**. The server installer must have registered its launcher. |
| **Over SSH** | First verify the host and key or agent authentication in Terminal with `ssh your-server-alias`. In the app, choose **Connect**, enter the same alias or `user@host`, and confirm. |
| **Local network** | On macOS 15 or later, allow Assistant under **System Settings > Privacy & Security > Local Network** when connecting to a LAN server. |

Remote connections use your SSH configuration and an authenticated loopback
tunnel. The app rejects unknown or changed host keys and does not prompt for
passwords. Quitting closes the tunnel, not the server or running tasks.

## Privacy and safety

| Area | What to know |
|---|---|
| **Credentials** | API tokens stay in session memory and are not saved in connection profiles. |
| **Conversation cache** | Conversation bodies and tool details are cached per installation. The cache is not separately encrypted. Clear it in **Settings > General > Clear conversation cache**. |
| **Attachments** | Files stay in memory unless you download them. |
| **Changes** | Configuration changes require review, destructive actions require confirmation, and uncertain writes are not replayed automatically. Server permissions still apply. |
| **Channels** | The channel filter is remembered per installation. **Assistant client** does not mean this Mac. The app asks before replying here to an email or Telegram conversation. |
| **Notifications** | Alerts require permission, omit message bodies, and stop when you quit the app. |

## Development

| Resource | What it covers |
|---|---|
| **[Build and contribution guide](docs/development.md)** | Xcode setup, signing, tests, and release checks. |
| **[Management API](https://github.com/rb81/assistant/blob/main/docs/building-clients.md)** | The shared API that the app uses for server operations. |
| **[Server security guide](https://github.com/rb81/assistant/blob/main/docs/security.md)** | Account isolation, permissions, and trust boundaries. |
| **[Apache 2.0 license](LICENSE)** | Same license as the Assistant server. |
