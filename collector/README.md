# Usage collector

Run `node collect.cjs --config <absolute-config-path>` for one normalized JSON snapshot.
Keep the parent's stdin pipe open; EOF cancels collection and owned child processes.

Codex uses app-server account/rateLimits/read; Antigravity uses /usage.
agyPath and claudeCredentialsPath may be null. Unconfigured providers are disconnected.
Claude's optional adapter reads existing credentials without refreshing or modifying them.

Required absolute paths: codexHome, userProfile, appData, localAppData, workDir, cachePath.
Executable paths: codexPath, agyPath. Timeout defaults to 20 seconds.
Only normalized usage is cached. Previous successful values survive failures.
Explicitly disabled connections clear their displayed history. No model prompts are sent.
