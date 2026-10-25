# Compatibility

Windows x64 only. Dependencies are pinned; unknown patch structures are rejected before app files are replaced.

| Component | Version |
|---|---|
| Private Node runtime | 24.14.0 |
| ChatGPT Layer | 1.1.4 |
| ASAR tooling | 3.4.1 |
| User entry points | Windows PowerShell 5.1; PowerShell 7 uses the Windows Appx compatibility module for package discovery |

## Validation record

| Sidebar source | Store app | Date | Checked |
|---|---|---|---|
| 1.1.0 | 26.1021.3705.0 | 2026-10-25 | Generated and verified a patched EXE/ASAR pair in an isolated output directory; source hashes and original ASAR payload preserved |

The record above is a patch-structure check, not a live sign-in or Store-update test.
Automated tests separately exercise synthetic profile/copy recovery, update failures, provider configuration, IPC failures, and the UI in headless Edge.
The already running desktop copy was not restarted to test 1.1.0. Live conversation resume, provider endpoints, and an actual Store update remain interactive checks after deployment.

If an app update changes the hooks or sidebar markup, run Doctor.cmd and keep using a verified copy or the Store original until compatibility is updated.
