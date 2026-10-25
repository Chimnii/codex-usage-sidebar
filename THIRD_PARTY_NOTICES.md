# Third-party notices

Unofficial project, not affiliated with or endorsed by OpenAI, Anthropic, Google,
or the ChatGPT Layer maintainers.

| Component | Version | License | Source |
|---|---|---|---|
| ChatGPT Layer | 1.1.4 | MIT, Copyright (c) 2026 Bennett | https://github.com/LightHaru/chatgpt-layer/tree/v1.1.4 |
| Electron ASAR | 3.4.1 | MIT, Copyright 2014 GitHub Inc. | https://github.com/electron/asar |
| Acorn | 8.15.0 | MIT | https://github.com/acornjs/acorn/tree/8.15.0 |

License texts are retained in LICENSES/. Acorn's parser, original license and
provenance are under patcher/repatch/vendor/acorn.
Layer and ASAR are downloaded at setup using package-lock.json; packages retain
their own licenses and transitive dependency notices. Layer's installer is not executed.

Local Layer changes: scripts/patch-layer-runtime.cjs makes configuration lookup
respect CODEX_HOME and disables automatic MCP synchronization into the shared user
configuration, which this sidebar does not use. It checks the version and exact
hooks and records before/after hashes.
The repatcher loads the upstream Layer loader into a copy created on the user's machine.

Setup downloads the official Node.js Windows archive specified in runtime.lock.json.
Its private installation retains Node.js's LICENSE and bundled dependency notices.
Node, Layer runtimes, dependencies and OpenAI app binaries are not included in source releases.

Dependency licensing does not grant rights to OpenAI software or override service terms.
Original project code uses the root MIT LICENSE.
