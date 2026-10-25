# Setup and recovery

1. On Windows x64, open the original Microsoft Store app and sign in once.
2. Keep this project in a permanent folder. Fully quit the app and run **Setup.cmd**.
3. Launch **ChatGPT with usage** from the Start menu. Right-click the shortcut and choose **Pin to taskbar** once. Later Setup runs update existing pins pointing to this copy, regardless of their filename.

Initial setup needs internet access. It verifies and installs a private Node runtime and pinned dependencies under `.local`; system Node and PATH are unchanged.
Setup prepares this private environment once even if the app previously used another Node or a development environment.
Later runs reuse the matching Node version and libraries. Libraries are reinstalled only when the lock file changes or required files are missing; existing provider settings are preserved.
Use one app at a time: the copy and original share login, conversations, and settings.
The copy is displayed as **ChatGPT with usage** and reuses the original app's icon files.
Window titles retain the conversation name alongside the app name; profile and cache paths are unchanged.
After changing the Windows theme, run `scripts/Install-UsageShortcut.ps1 -UpdateExistingPin` if a pinned shortcut still uses the previous theme's icon.

| Command | Purpose |
|---|---|
| Setup.cmd | Install, apply settings/source changes, and create the shortcut |
| Launch.cmd | Verify/prepare the copy and launch it; normally use the Start menu shortcut |
| Update.cmd | Check/update the Store original, repatch the copy, and launch |
| Restore.cmd | Restore the previous copy; does not roll back conversations or settings |
| Doctor.cmd | Read-only version, usage, UI, update, and recovery diagnostics |
| Uninstall.cmd | Remove the managed copy and shortcuts; retain the original, profile, and project sources |

## Optional providers

Antigravity connects when its CLI is found at the default location. Claude is disabled on new installs.
With the app closed, run in the project directory:

```powershell
.\scripts\Setup.ps1 -DisableAntigravity
.\scripts\Setup.ps1 -AntigravityPath 'C:\Tools\agy\agy.exe'
.\scripts\Setup.ps1 -EnableClaude
.\scripts\Setup.ps1 -DisableClaude
```

Claude reads existing Claude Code credentials. It does not sign in or refresh credentials. Direct OAuth usage queries are experimental; see [data and authentication (Korean)](DATA.md).
Existing provider settings are preserved during setup. [Display and refresh options](OPTIONS.md) live under `usage` in `.local/settings.json`.
After editing settings, close the app and run Setup.cmd. Do not share the settings file.

## Updates and recovery

- Store checks run every six hours; Help → Check for updates checks immediately. Failed checks retry after one hour.
- Startup also compares the installed original with the copy. An already updated original can be repatched even if Store queries fail.
- The in-app update action waits for normal app exit. Finish your work and fully quit the app.
- Restore.cmd keeps the restored version until the next Setup.cmd or Update.cmd. If active files are damaged, a verified previous copy can still be restored; one damaged copy is retained under `.local/copy/damaged` until the next repair.
- To update this project's source, replace source files in the same folder and run Setup.cmd. Project sources are not downloaded automatically.
- Run Doctor.cmd for diagnostics. `powershell -NoProfile -File scripts/Doctor.ps1 -Json` produces a sanitized report; do not share raw settings or logs.
- If needed, quit the copy and return to the original Store app. You may also update the original manually and run Setup.cmd.
- To move the project, quit the app, run Uninstall.cmd at the old location, download **sources only** into the new folder, and run Setup.cmd. Do not move `.local` or reuse the old shortcut. The original profile retains your login and conversations.
