# Codex Usage Sidebar

**English** · [한국어](README.ko.md)

An unofficial local extension that keeps GPT, Antigravity Gemini/Argon, and Claude usage always visible in the Codex Windows sidebar.

- Usage gauges, percentages, and reset times, refreshed about once a minute
- A separate app copy that preserves the original and uses your existing login and conversations
- Taskbar shortcut, Store update checks, and automatic repatching after updates
- Antigravity and Claude are optional; GPT works on its own

Disabled providers stay hidden. Hover or focus the panel to refresh; display order, language, and polling intervals are configurable.

## How it works

Injects [ChatGPT Layer](https://github.com/LightHaru/chatgpt-layer) into `app.asar` and updates the EXE's ASAR integrity hash.
Patches a separate copy to avoid Store directory write restrictions, sharing the original user profile.

## Get started

On Windows x64, install the original app from Microsoft Store and sign in once.
Download the source into a permanent folder, fully quit the app, and run **Setup.cmd**.
Setup installs a project-local Node runtime and pinned dependencies; administrator rights are not required.

Launch **Codex Usage Sidebar** from the Start menu and pin it to the taskbar.
Use **Help → Check for updates** or the update button at the bottom of the app to check for or apply updates.

[Setup and recovery](docs/SETUP.en.md) · [Display options](docs/OPTIONS.md) · [Compatibility](docs/COMPATIBILITY.md)

Run **Doctor.cmd** for a read-only health report. [Architecture and development (Korean)](docs/DEVELOPMENT.md).

App binaries and account data are not distributed. The copy shares user data with the original app.
This is not an official OpenAI product or an approved plugin; applicable service terms remain separate from the project license.
Direct Claude OAuth usage queries are experimental and disabled by default on new installations.

MIT · [Third-party notices](THIRD_PARTY_NOTICES.md) · [Authentication and data handling (Korean)](docs/DATA.md)
