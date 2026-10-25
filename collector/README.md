# Usage collector

Run `node collect.cjs --config <absolute-config-path>` for one normalized JSON snapshot.
Keep the parent's stdin pipe open; EOF cancels collection and owned child processes.

Codex uses app-server account/rateLimits/read; Antigravity uses /usage.
agyPath and claudeCredentialsPath may be null. Disabled providers are hidden;
an explicitly enabled provider with a missing path remains a configuration error.
Claude's optional adapter reads existing credentials without refreshing or modifying them.

Required absolute paths: codexHome, userProfile, appData, localAppData, workDir, cachePath.
Executable paths: codexPath, agyPath. Collection defaults to 60 seconds per provider,
with a 20-second timeout. `usage.providers.<id>.intervalSeconds` (30–3600) and
`timeoutSeconds` (1–60) override those defaults. Schedules persist in the cache.
Only normalized usage is cached. Previous successful values survive failures.
Explicitly disabled connections clear their displayed history. No model prompts are sent.
`--refresh` bypasses ordinary polling intervals, but never Claude's retry backoff.
Only allowlisted error codes, durations and failure counts accompany usage data.
Successful CLI requests get a short EOF exit grace before owned-process cleanup.
