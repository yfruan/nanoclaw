# Intent: src/index.ts modifications

## What changed
Added Feishu as a channel alongside WhatsApp, introducing multi-channel infrastructure.

## Key sections

### Imports (top of file)
- Added: `FeishuChannel` from `./channels/feishu.js`

### Multi-channel infrastructure
- Added: `const channels: Channel[] = []` array to hold all active channels
- Changed: `processGroupMessages` uses `findChannel(channels, chatJid)` instead of `whatsapp` directly
- Changed: `startMessageLoop` uses `findChannel(channels, chatJid)` instead of `whatsapp` directly

### main()
- Added: `channelOpts` shared callback object for all channels
- Added: `onRealtimeMessage` callback for handling /register command
- Added: Feishu channel creation and connection
- Changed: WhatsApp connection is commented out (Feishu only mode)
- Changed: shutdown iterates `channels` array instead of just `whatsapp`
- Changed: subsystems use `findChannel(channels, jid)` for message routing

## Invariants
- All existing message processing logic (triggers, cursors, idle timers) is preserved
- The `runAgent` function is completely unchanged
- State management (loadState/saveState) is unchanged
- Recovery logic is unchanged
- Container runtime check is unchanged
