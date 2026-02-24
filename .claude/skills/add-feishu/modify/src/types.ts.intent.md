# Intent: src/types.ts modifications

## What changed
Added Feishu-specific `chat_type` field to `NewMessage` interface.

## Key sections

### NewMessage interface
- Added: `chat_type?: 'private' | 'group'` - Feishu chat type to distinguish between private DMs and group chats
