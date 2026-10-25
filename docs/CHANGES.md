# Changes

## 1.1.0

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
