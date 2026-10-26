# Changes

## Unreleased

- Add a README screenshot with personal chat titles and profile details redacted.
- Allow setup while the Store original is running, warn at completion, and guard direct copy launches against a running original.
- Enable Claude on new installations and show missing/expired credentials as Disconnected; preserve explicit disabled settings and previous successful values.
- Keep window and taskbar titles fixed to ChatGPT with usage without exposing conversation names.
- Show each setup phase on a separate line and keep Setup.cmd open after success or failure until a key is pressed.
- Keep one managed app after updates; retain the old slot only during the swap. Restore.cmd now rebuilds from the installed original, including missing or damaged copies.
- Copy resources with Windows robocopy and verify the file inventory and sizes. Generate the EXE/ASAR pair directly from the source and move it into staging without original-pair or duplicate patch backups.
- Reuse the app's Codex CLI for collection, reuse prepared Layer assets, and remove the private Node download after installation.
- Keep structural hook detection, source snapshot and patched pair checks; use larger stream buffers and avoid redundant managed-staging hash passes. Report preparation phase durations.

## 1.1.0

- Use ChatGPT with usage for shortcut and window display names, preserve conversation titles and profile identity, and reuse the original app's themed icons.
- Name the managed-copy shortcuts ChatGPT with usage; migrate owned legacy shortcuts and update existing pins by target without changing original-app shortcuts.
- Clarify that hovering reveals a manual refresh button and that display preferences live in the settings file.
- Fix Setup and Uninstall in fresh PowerShell processes by importing their settings module explicitly; clarify private dependency reuse.
- Restore a verified previous copy even when the active copy is damaged; keep bounded recovery evidence.
- Preserve the last usage values while reporting IPC failures and delayed data accurately.
- Separate local repatch detection from Microsoft Store connectivity and guard direct launch during updates.
- Disable unused Layer MCP synchronization into the shared profile.
- Respect optional providers in diagnostics; add Doctor.cmd and bounded launch-report retention.
- Add compact manual refresh, Korean/English strings, display preferences, and provider polling options.
- Reduce unnecessary DOM work and allow owned collector children to exit gracefully.
- Exclude documentation and test-only changes from copy rebuild decisions.
- Add isolated recovery, offline update, IPC timeout, provider configuration, and responsive UI tests.

## 1.0.0

- Initial source-only release with managed app copies, usage collection, and Store update integration.
