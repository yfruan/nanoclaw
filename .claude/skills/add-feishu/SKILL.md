---
name: add-feishu
description: Add Feishu (Lark) as a messaging channel. Supports group chats, DMs, and self-registration via /register command.
---

# Add Feishu Channel

This skill adds Feishu (飞书/Lark) support to NanoClaw using the skills engine for deterministic code changes, then walks through interactive setup.

## Phase 1: Pre-flight

### Check if already applied

Read `.nanoclaw/state.yaml`. If `feishu` is in `applied_skills`, skip to Phase 3 (Setup). The code changes are already in place.

### Ask the user

Use `AskUserQuestion` to collect configuration:

AskUserQuestion: Do you have Feishu app credentials (App ID and App Secret), or do you need to create one?

If they have credentials, collect them now. If not, we'll create an app in Phase 3.

## Phase 2: Apply Code Changes

Run the skills engine to apply this skill's code package. The package files are in this directory alongside this SKILL.md.

### Initialize skills system (if needed)

If `.nanoclaw/` directory doesn't exist yet:

```bash
npx tsx scripts/apply-skill.ts --init
```

Or call `initSkillsSystem()` from `skills-engine/migrate.ts`.

### Apply the skill

```bash
npx tsx scripts/apply-skill.ts .claude/skills/add-feishu
```

This deterministically:
- Adds `src/channels/feishu.ts` (FeishuChannel class implementing Channel interface)
- Three-way merges Feishu support into `src/index.ts` (multi-channel support, findChannel routing)
- Three-way merges Feishu config into `src/config.ts` (FEISHU_APP_ID, FEISHU_APP_SECRET)
- Three-way merges Feishu config into `src/types.ts` (chat_type field)
- Installs the `@larksuiteoapi/node-sdk` npm dependency
- Records the application in `.nanoclaw/state.yaml`

If the apply reports merge conflicts, read the intent files:
- `modify/src/index.ts.intent.md` — what changed and invariants for index.ts
- `modify/src/config.ts.intent.md` — what changed for config.ts
- `modify/src/types.ts.intent.md` — what changed for types.ts

### Validate code changes

```bash
npm run build
```

Build must be clean before proceeding.

## Phase 3: Setup

### Create Feishu App (if needed)

If the user doesn't have app credentials, tell them:

> Create a custom app at https://open.feishu.cn/app:
>
> 1. Click "Create Custom App"
> 2. Enable **Bot** capability
> 3. Add **Permissions**:
>    - `im:message` - Send/receive messages
>    - `im:message:send_as_bot` - Send as bot
>    - `contact:user.base:readonly` - Read user info
>    - `im.chat:readonly` - Read chat info
>    - `im:resource:download` - Download images/files (for image vision)
> 4. **Event Subscriptions**: Subscribe to `im.message.receive_v1`
> 5. Set connection mode to **WebSocket** (not callback URL)
> 6. Get **App ID** and **App Secret** from Credentials page

Wait for the user to provide credentials.

### Configure environment variables

Add credentials to `.env`:

```bash
FEISHU_APP_ID=your_app_id
FEISHU_APP_SECRET=your_app_secret
```

### Build and restart

```bash
npm run build
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # macOS
# Linux: systemctl --user restart nanoclaw
```

## Phase 4: Registration

### Test self-registration

Tell the user:

> In Feishu:
> 1. Add the bot to a group or start a DM
> 2. Send `/register` to register this chat
> 3. The bot will respond with confirmation

Wait for the user to register.

## Phase 5: Verify

### Test the connection

Tell the user:

> Send a message in your registered Feishu channel:
> - For private chat: Any message works
> - For group: @mention the bot
>
> The bot should respond within a few seconds.

### Check logs if needed

```bash
tail -f logs/nanoclaw.log
```

## Troubleshooting

### Bot not receiving messages

1. Check credentials: Verify FEISHU_APP_ID and FEISHU_APP_SECRET are in `.env`
2. Check WebSocket: `tail -f logs/nanoclaw.log | grep -i feishu`
3. Verify event subscription is set to WebSocket mode
4. Check app is published with active version

### Registration issues

```bash
sqlite3 store/messages.db "SELECT * FROM registered_groups WHERE jid LIKE 'oc_%' OR jid LIKE 'ou_%'"
```

## After Setup

The Feishu channel supports:
- Text messages in registered chats
- Rich text posts
- Image messages (with automatic download for vision)
- File attachments
- @mention translation
- Self-registration via `/register` command
- WebSocket real-time messaging (no polling needed)

## Image Vision

Image vision uses the minimax MCP server inside the container. When an image is sent:
1. Feishu channel downloads the image to `data/ipc/{groupFolder}/images/`
2. The image path is added to message as `<image_path>...</image_path>`
3. Agent uses `mcp__minimax__understand_image` to analyze

Ensure `MINIMAX_API_KEY` and `MINIMAX_API_HOST` are set in `.env` for vision to work.

## Removal

To remove Feishu integration:

1. Delete `src/channels/feishu.ts`
2. Remove Feishu code from `src/index.ts`
3. Remove FEISHU_APP_ID and FEISHU_APP_SECRET from `.env`
4. Remove Feishu registrations from SQLite: `sqlite3 store/messages.db "DELETE FROM registered_groups WHERE jid LIKE 'oc_%' OR jid LIKE 'ou_%'"`
5. Uninstall: `npm uninstall @larksuiteoapi/node-sdk`
6. Rebuild and restart
