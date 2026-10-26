# Display and refresh options

복사본을 닫고 `.local/settings.json`의 `usage` 항목을 수정한 뒤 Setup.cmd를 실행하세요. 나머지 경로·계정 설정은 유지합니다.

Close the copy, edit the optional `usage` object in `.local/settings.json`, and run Setup.cmd. Keep the other settings intact. Omitted values use the defaults.

```json
{
  "usage": {
    "language": "auto",
    "providerOrder": ["codex", "antigravity", "claude"],
    "hiddenProviders": [],
    "windowOrder": {},
    "hiddenWindows": {},
    "providers": {
      "codex": { "intervalSeconds": 60, "timeoutSeconds": 20 },
      "antigravity": { "intervalSeconds": 60, "timeoutSeconds": 20 },
      "claude": { "intervalSeconds": 60, "timeoutSeconds": 20 }
    }
  }
}
```

| Option | Values |
|---|---|
| language | `auto`, `ko`, or `en` |
| providerOrder | Provider IDs in the desired order; omitted providers follow |
| hiddenProviders | Provider IDs to hide from the panel |
| windowOrder | Provider ID → array of exact usage-window IDs, ordered first |
| hiddenWindows | Provider ID → array of exact usage-window IDs to hide |
| providers.*.intervalSeconds | 30–3600 seconds; default 60 |
| providers.*.timeoutSeconds | 1–60 seconds; default 20 |

For example, `"hiddenProviders": ["claude"]` hides Claude. Hiding a provider only affects display; use the Setup switches to disable its connection.
Hover a usage row to find its exact window ID. IDs are also available in the local `usage-cache.json` under `.local/copy/active/layer-data/tweak-data/local.sidebar-usage-demo/`. Do not share the whole `.local` directory.

The panel keeps the last successful values on failure and marks delayed data. Reset deadlines do not turn old readings into an invented 0%.
Hover or focus the panel to reveal its refresh action. Manual refresh coalesces concurrent requests and still honors provider rate-limit backoff.
