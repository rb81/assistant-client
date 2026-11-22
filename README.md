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
| **Chats** | Search conversations, mark them read or unread, read Markdown tables and aligned text diagrams, select multiline prose, copy any complete message, open attachments, play audio, and inspect tool activity. Replies use your configured assistant's name. |
| **Reminders** | Check schedules and past results, with read/unread state preserved across launches. Start a new chat to ask about a scheduled run. |
| **Connections** | Open service health, activation, connection diagnostics, and request timings directly from the sidebar. |
| **Data** | Use the full-width browser to preview images with zoom, text/code, Markdown, PDF, Office documents and fonts, or play supported audio/video. Download and manage workspace files. |
| **Activity** | Use the toolbar bell for permission requests, real reply/update notices, and operation history. Unconfirmed actions are distinct from approval requests and are never automatically repeated. |
| **Settings** | Restore the complete cached menu without progressively appearing sections. Keep ordinary setup beside each feature's enable switch, with power-user tuning under Advanced. Retain drafts while navigating, edit instructions in a bounded Markdown editor, and review before saving. A persistent **Review & Apply** banner lists saved changes awaiting activation. Skills prefetch and show 20 per page; adjustable pane widths are remembered. |
| **OpenRouter models** | Search cached, capability-filtered models and restrict hosting providers. Require ZDR in server settings; manage weekly/manual catalog refresh locally. |
| **Model settings** | Edit individual model choices directly under **Settings > Models & Voice**, including disabled features. Provider, voice, safety, and tuning controls stay in linked settings pages. Changes use the same reviewed draft. |
| **Live updates** | Receive resumable updates with polling fallback and optional macOS notifications while the app is open. |

## Download

| Item | Details |
|---|---|
| **Download** | Look for a signed, notarized build on [GitHub Releases](https://github.com/rb81/assistant-client/releases), or [build from source](docs/development.md). |
| **Requirements** | macOS 15 or later and a running [Assistant server](https://github.com/rb81/assistant#install). The app does not bundle the server. |
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
| **File previews** | Reads are digest-verified. Quick Look and media previews use private temporary files, removed on dismissal or normal shutdown; an abnormal termination can leave files in the OS temporary directory. Text, image, Markdown and PDF previews stay in memory. HTML/SVG display as inert source, not web pages. |
| **Settings menu cache** | Only installation-scoped navigation descriptors are persisted, never effective settings, credentials, instruction bodies or server source. Editing waits for a current server response. |
| **Changes** | Configuration changes require review, destructive actions require confirmation, and uncertain writes are not replayed automatically. Server permissions still apply. |
| **Channels** | The channel filter defaults to **Assistant client** and remembers your choice per installation. **Assistant client** does not mean this Mac. The app asks before replying here to an email or Telegram conversation. |
| **Notifications** | Alerts require permission, omit message bodies, and stop when you quit the app. |

OpenRouter's public catalog indicates model and ZDR eligibility, not guaranteed
access under your account's guardrails. ZDR routing, improved settings metadata,
recovery of missing operation receipts, and saved-change activation reviews
require the updated server. Activation history starts with saves made through the
updated management service; earlier saves cannot be reconstructed. Model-list
refresh preferences and caches stay on this Mac.

Quick model editing requires an updated server advertising
`configuration.model-settings` and supplying selector/link metadata. Model
controls show your draft; effective-model and activation notices describe saved
values, not verified running models or live provider access. Other controls stay
in their linked pages.

**Review changes** opens a modal with validation and save actions, so review
never depends on scrolling to the end of a page. **Back** and **Forward**
(Command-[ / Command-]) navigate visited pages and settings sections, retaining
drafts, search, and scroll positions for the current connection.

## Development

| Resource | What it covers |
|---|---|
| **[Build and contribution guide](docs/development.md)** | Xcode setup, signing, tests, and release checks. |
| **[Management API](https://github.com/rb81/assistant/blob/main/docs/building-clients.md)** | The shared API that the app uses for server operations. |
| **[Server security guide](https://github.com/rb81/assistant/blob/main/docs/security.md)** | Account isolation, permissions, and trust boundaries. |
| **[Apache 2.0 license](LICENSE)** | Same license as the Assistant server. |
