# Layer extension

index.js renders usage in the sidebar. main-bridge.cjs supervises the independent
collector and sends sanitized snapshots over IPC. update-bridge.cjs shares one Store
query and one timer between background checks and update-menu.cjs.

The renderer reads memory every five seconds; service collection runs about once a minute.
Authentication data never reaches the renderer. stop() removes owned UI, listeners,
timers and processes. See the root README for setup.
