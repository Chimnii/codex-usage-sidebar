# Layer extension

index.js renders usage in the sidebar. main-bridge.cjs supervises the independent
collector and sends sanitized snapshots over IPC. update-bridge.cjs shares one Store
query and one timer between background checks and update-menu.cjs.

The renderer reads memory every five seconds (15 seconds while hidden). IPC timeouts
keep the last percentages, mark them delayed and allow later polling to recover.
The small refresh button appears on hover or keyboard focus; window resume refreshes
only when collection is due. Neither action bypasses Claude's retry backoff.

`usage` settings support `language` (`auto`, `ko`, `en`), `providerOrder`,
`hiddenProviders`, and per-provider `windowOrder` / `hiddenWindows` arrays of exact
window IDs. IDs and last-success/error/retry details are available in row tooltips.
Hiding rows is presentation-only; disable a provider to stop collecting it.

Authentication data never reaches the renderer. Shell mutation checks ignore unrelated
chat streaming; diagnostic layout reports are limited to initial mounts. `stop()` removes
owned UI, listeners, timers and processes. See the root setup guide for settings.
