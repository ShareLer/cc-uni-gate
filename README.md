# CC Uni Gate

Local model-level provider manager for Codex and Claude-style API clients.

## Native macOS App

Run the Swift menu bar app:

```bash
swift run UniGateApp
```

It creates an `API` item in the macOS status bar. The menu is organized as:

```text
CC Uni Gate
  Codex
    gpt-5.5
      dasu-gpt-plus-0.077 · openai_responses
      dasu-gpt-pro-0.2 · openai_responses
      gpt-free · openai_responses
  Claude Code
    auto
      Dasu-claude · anthropic
```

Use `Settings...` from the status bar menu to choose which models appear in
the menu, set the local proxy port, and override provider protocol detection.
With no preferences file, all models are shown. Saving an empty selection hides
all model entries.

Use the `Copy` button in `Settings... -> General` when configuring Codex or
another OpenAI-compatible client:

```text
http://127.0.0.1:17888/codex
```

The selected provider is written to:

```text
~/Library/Application Support/UniGate/routes.json
```

Routes are keyed by app and model, for example:

```text
codex:gpt-5.5
claude:auto
claude-desktop:claude-sonnet-4-6
```

The status bar model visibility preference is written to:

```text
~/Library/Application Support/UniGate/preferences.json
```

Proxy logs are written to:

```text
~/Library/Application Support/UniGate/logs/unigate.log
```

Inspect the real cc-switch DB from Swift without printing secrets:

```bash
swift run UniGateInspect
```

Run Swift tests:

```bash
swift test
```

Run a real end-to-end smoke test against the configured local port:

```bash
./scripts/e2e-smoke.sh
```

This sends real requests through UniGate to the configured upstream providers
and may consume provider quota. By default it probes `deepseek-v4-flash` for
Codex and `Deepseek-v4-flash` for Claude Code.

Build, install, and launch the local macOS app:

```bash
./scripts/build-install-run.sh
```

## Client Setup

For Codex/OpenAI-compatible clients, set the base URL to:

```text
http://127.0.0.1:17888/codex
```

Keep the model name as the logical model configured in cc-switch, for example:

```text
gpt-5.5
```

The manager reads the model from the request body and forwards it to the active
Codex route selected in the status bar menu.

## Current MVP

Swift native app:

- Reads provider definitions from `/Users/didi/.cc-switch/cc-switch.db` in
  read-only mode.
- Builds model -> provider menu items in the macOS status bar.
- Lets the user choose which models are visible in the status bar menu.
- Exposes local manager and proxy endpoints at `http://127.0.0.1:17888`.
- Forwards protocol-preserving upstream responses, including SSE/chunked
  streaming responses.
- Provides a status bar shortcut to open the local app folder.
- Shows proxy status and writes proxy diagnostics to a local log file.
- Supports per-provider protocol overrides in Settings without writing to
  `cc-switch.db`.
- Settings filters Models and Providers by app type so Codex, Claude Code, and
  Claude Desktop configuration is not presented as one flat list.
- Keeps model-level route state in
  `~/Library/Application Support/UniGate/routes.json`.
- Migrates legacy app data from `~/Library/Application Support/API Manager`
  into `~/Library/Application Support/UniGate` on startup.
- Never writes to `cc-switch.db`.
- Does not print provider secrets in inspect output or manager catalog output.

## Manager Endpoints

```text
GET  /__manager/health
GET  /__manager/catalog
POST /__manager/reload
POST /__manager/routes
```

Route switch body:

```json
{
  "logicalModel": "gpt-5.5",
  "providerRef": "cc-switch:codex:c1e4c21e-950d-473b-9be8-515d8c8451cc"
}
```

Proxy endpoints:

```text
POST /codex/v1/responses
POST /codex/v1/responses/compact
POST /codex/v1/chat/completions
POST /claude-code/v1/messages
POST /claude-code/v1/messages/count_tokens
POST /claude-desktop/v1/messages
POST /claude-desktop/v1/messages/count_tokens
```

Compatibility endpoints:

```text
POST /openai/v1/responses
POST /openai/v1/responses/compact
POST /openai/v1/chat/completions
POST /anthropic/v1/messages
POST /anthropic/v1/messages/count_tokens
```

## Important Limitation

The Swift app proxy supports protocol-preserving routes and non-streaming text
bridging from Codex Responses to OpenAI Chat upstreams. If another transform is
required, the proxy fails closed with a clear error. OpenAI
Responses-to-Responses routes are streamed through without buffering the whole
upstream response.

For Codex providers, this app treats Codex TOML `wire_api` as the local client
protocol. cc-switch `meta.apiFormat` describes the real upstream protocol used
behind the local route.

## Next Implementation Step

Run a real Codex/OpenAI-compatible client against the installed app and verify
non-streaming, streaming, tool-call, and upstream error paths.
