# App manifest contract

> How the daemon describes an app to the client, and how each field
> reshapes the UI. The client is a **runtime** — it doesn't ship
> hardcoded app logic. A well-written `app.yaml` should be able to
> turn it into anything from a one-field chat interface to a
> full-featured IDE.

## Endpoint

```
GET /api/apps/{app_id}/manifest
Authorization: Bearer <user token>
Accept: application/json, application/yaml
```

The client accepts:

1. **JSON** (`application/json`) — preferred, cheaper to parse.
2. **Raw YAML** (`application/yaml` or `text/yaml`) — the daemon can
   just serve the `app.yaml` file as-is; the client has a built-in
   YAML parser.

Both shapes are mapped to the same `AppManifest` model. A 404 is
fine: the client falls back to synthesising a manifest from the
basic `AppSummary` fields (`name`, `icon`, `greeting`, etc.) so
older daemons keep working.

## Schema

The manifest mirrors the on-disk `app.yaml`. Unknown fields are
ignored. Missing fields get sensible defaults.

### `app:` — identity + presentation

| Field | Type | Default | UI surface |
|-------|------|---------|-----------|
| `app_id` | string | **required** | used for API / socket routing |
| `name` | string | `""` | chat header, empty state, session list |
| `version` | string | `"1.0"` | "about" drawer |
| `description` | string | `""` | app marketplace card |
| `icon` | string (emoji) | `""` | header badge, empty state badge |
| `color` | string (hex) | `""` | accent tint for badge, chips, send button, pressure bar |
| `category` | string | `""` | marketplace filter |
| `author` | string | `""` | marketplace attribution |
| `tags` | list\<string\> | `[]` | marketplace filter |
| `quick_prompts` | list | `[]` | clickable chips on the chat empty state |

### `app.quick_prompts[]`

| Field | Type | Description |
|-------|------|-------------|
| `label` | string | Shown on the chip. |
| `icon` | string (emoji) | Rendered left of the label. Optional. |
| `message` | string | Pre-filled into the input on tap. Caret goes to the end so the user can continue typing. |

### `execution:` — chat runtime behaviour

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `mode` | enum | `"conversation"` | Drives the whole chat UX. See table below. |
| `max_turns` | int | `20` | Soft cap shown in the turn counter. |
| `timeout` | int (sec) | `120` | Client watchdog for stuck spinner. |
| `workspace_mode` | enum | `"auto"` | See table below. |
| `greeting` | string | `""` | Big text on the empty state ("What can I do for you?"). |

### `execution.mode`

The client recognises three runtime shapes today. Pick the one that
matches how your app behaves:

| Value | UX | Full view |
|-------|----|-----------|
| `conversation` *(default)* | Classic chat — multi-turn thread, session drawer, replay, queueing | `ChatPanel` |
| `oneshot` | **Stateless, API-style**: prompt → Run → result. No session drawer, no timeline, no history shown. Each Run creates a fresh session server-side | `OneshotPanel` |
| `background` | **Autonomous**: cron / webhook / inbox-driven. No composer. User observes triggers, runs, health | `BackgroundDashboard` |

Aliases accepted (case-insensitive): `one_shot`, `one-shot`,
`single` → oneshot ; `bg`, `autonomous` → background ; `chat` →
conversation.

### Oneshot semantics

The app behaves like an HTTP endpoint the user calls interactively:

1. User types a prompt, presses **Run** (or Ctrl/Cmd+Enter).
2. Client creates a **fresh session** via `POST /api/apps/{id}/sessions`.
3. Client sends the message via `POST .../messages`.
4. Assistant response streams into a single card (tool calls,
   diffs, agent events all render normally — the full renderer
   toolkit is reused from ChatPanel).
5. When the turn finishes, the card stays on screen with a
   **"New run"** affordance. Clicking it clears the view so the
   user can run the app again — against a new session.

No session drawer, no timeline of past runs in the UI. If the
daemon persists them server-side they can be surfaced in the
future via a "history" tab; for now the UX is deliberately
ephemeral — same feel as an API playground.

### Background semantics

The user never types. `BackgroundDashboard` replaces the whole
chat area and shows:

- Hero identity + live pulse
- 4-metric stats card + 24h sparkline
- Triggers (cron / webhook / inbox) with per-trigger metrics
- Channels health
- Per-user sessions
- Recent activations (clickable → drawer with full run detail)

### `execution.workspace_mode`

| Value | Chat layout | Workspace panel |
|-------|------------|-----------------|
| `none` | Full-width chat, no toggle | **Hidden**. Not reachable. |
| `optional` | Toggle visible | Opens on-demand, starts closed. |
| `required` | Toggle visible + "select workspace" banner | Forced open + user must pick a path before sending. |
| `auto` *(default)* | Toggle visible | Decided by whatever opens it first (tool calls auto-open it). |

### `features:` — fine-grained UI toggles

Every flag **defaults to `true`** so minimal manifests keep the full
composer. Set a flag to `false` to hide that element entirely.

```yaml
features:
  voice: false            # hides microphone button
  attachments: false      # hides paperclip / attach menu
  tools_panel: false      # hides Tools browser button
  snippets: true          # hides snippets library button
  tasks_panel: false      # hides background tasks button
  memory_panel: false     # hides memory drawer (goal/todos)
  context_ring: true      # hides context pressure gauge
  markdown: true          # fallback to plain text rendering
  slash_commands: false   # disables "/" command palette
  message_actions: true   # removes copy / retry buttons
  status_pills: true      # removes Live / Reconnecting pills
  token_badges: false     # hides per-message token footer
```

### `capabilities:` — permission surface

| Field | Type | UI surface |
|-------|------|-----------|
| `default_policy` | `"auto"` / `"prompt"` / `"deny"` | Approval banner mode |
| `grant[]` | list | Capabilities drawer enumerates grants |
| `grant[].module` | string | e.g. `memory`, `web` |
| `grant[].actions` | list\<string\> | e.g. `[search, fetch, extract]` |

### `theme:` — optional palette overrides

Overrides `app.color`. Rarely used — most apps stick with a single
accent.

```yaml
theme:
  accent: "#6EE7B7"
  background: "#0B1220"
```

## Backwards compatibility

Apps that don't ship a manifest (daemon returns 404) still work:

1. The client synthesises an `AppManifest` from the existing
   `AppSummary` fields (`name`, `icon`, `color`, `greeting`,
   `workspace_mode`).
2. All `features.*` flags default to `true`.
3. No quick prompts, no slash commands.

Apps that ship a *partial* manifest get the declared fields + the
defaults for everything else.

## End-to-end example — your sample `digitorn-chat`

Given the YAML you shared (workspace_mode: none, greeting, quick
prompts, memory/web/context_builder grants), the client renders:

- Header: 💬 chip (`#4f8cff` tint) + "Digitorn Chat" title.
- No workspace toggle anywhere (`workspace_mode: none`).
- Empty state: accent-colored badge + "Digitorn Chat" + your
  greeting + 4 clickable chips (Explain, Search, Help me write,
  Brainstorm).
- Composer: attach / tools / snippets / mic / send — all visible
  because no `features:` block was declared, so defaults kick in.
- Capabilities drawer: memory (4 actions) + web (3) + context_builder (1).

## Future extensions (roadmap)

These aren't parsed yet but the schema anticipates them:

- `workspace.panels[]` — list of custom workspace tabs declared by the app.
- `chat.slash_commands[]` — command palette entries per app.
- `widgets.*` — widget tree definitions (partially already supported via the existing widgets_v1 system).
- `theme.font_family`, `theme.radius` — full palette overrides.
- `approvals[]` — declarative approval form templates.
