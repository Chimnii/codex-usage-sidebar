# Tests

Run `npm test` and `npm run test:windows` after `npm ci --ignore-scripts`.
PowerShell cases also run with `pwsh -File scripts/Test-Windows.ps1`.

Tests generate synthetic apps, credentials and profiles under .local/test-work.
They do not patch installed apps, launch real desktop copies or query real accounts.
UI tests use headless Microsoft Edge with synthetic content.
Reports and images stay in ignored .local/test-results storage.
Store installation and interactive app use are separate manual checks.
