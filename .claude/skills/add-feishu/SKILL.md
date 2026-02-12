---
name: add-feishu
description: Add Feishu (Lark) as a messaging channel. Supports group chats, DMs, and self-registration via /register command.
---

# Add Feishu Channel

This skill adds Feishu (飞书/Lark) support to NanoClaw. Features:

- **WebSocket real-time messaging** - No polling needed
- **Rich text support** - Posts, images, files, media
- **Self-registration** - Users can register via `/register` command
- **Groups and DMs** - Supports both chat types

## Prerequisites

### 1. Install Feishu SDK

```bash
npm install @larksuiteoapi/node-sdk
```

### 2. Create Feishu App

Tell the user:

> Create a custom app at https://open.feishu.cn/app:
>
> 1. Click "Create Custom App"
> 2. Enable **Bot** capability
> 3. Add **Permissions**:
>    - `im:message` - Send/receive messages
>    - `im:message:send_as_bot` - Send as bot
>    - `contact:user.base:readonly` - Read user info
>    - `im.chat:readonly` - Read chat info
> 4. **Event Subscriptions**: Subscribe to `im.message.receive_v1`
> 5. Set connection mode to **WebSocket** (not callback URL)
> 6. Get **App ID** and **App Secret** from Credentials page

## Implementation

### Step 1: Update `src/types.ts`

Add Feishu-specific properties to `RegisteredGroup` and `NewMessage`:

```typescript
export interface RegisteredGroup {
  name: string;
  folder: string;
  trigger: string;
  added_at: string;
  containerConfig?: ContainerConfig;
  requiresTrigger?: boolean;
  allowedUsers?: string[]; // Feishu user IDs for private chat access
  isMainSession?: boolean; // Feishu main session marker
}

export interface NewMessage {
  id: string;
  chat_jid: string;
  sender: string;
  sender_name: string;
  content: string;
  timestamp: string;
  chat_type?: 'private' | 'group'; // Feishu chat type
  is_from_me?: boolean;
}
```

### Step 2: Update `src/db.ts`

Add Feishu-specific database functions:

```typescript
export interface FeishuSender {
  sender_id: { open_id?: string; user_id?: string; union_id?: string };
  sender_type?: 'user' | 'app' | string;
  tenant_key?: string;
}

export interface FeishuMessage {
  message_id: string;
  root_id?: string;
  parent_id?: string;
  chat_id: string;
  chat_type: 'p2p' | 'group';
  message_type: string;
  content: string;
  create_time?: string;
  mentions?: Array<{ key: string; id: { open_id?: string }; name: string }>;
}

export function storeFeishuMessage(
  message: FeishuMessage,
  sender: FeishuSender,
  chatJid: string,
  isFromMe: boolean,
  resolvedName?: string,
): void {
  const parsed = JSON.parse(message.content);
  let text = '';
  let mediaInfo: string | undefined;

  switch (message.message_type) {
    case 'text':
      text = parsed.text || '';
      break;
    case 'post':
      const title = parsed.zh_cn?.title || parsed.en_us?.title || '';
      text = title ? `${title}\n\n[Rich Text]` : '[Rich Text Message]';
      break;
    case 'image':
      text = '<media:image>';
      mediaInfo = `image:${parsed.image_key}`;
      break;
    case 'file':
      text = '<media:document>';
      mediaInfo = `file:${parsed.file_key}`;
      break;
    default:
      text = `[${message.message_type}]`;
  }

  const fullContent = mediaInfo ? `${text} [${mediaInfo}]` : text;
  const timestamp = message.create_time
    ? new Date(parseInt(message.create_time, 10)).toISOString()
    : new Date().toISOString();

  db.prepare(
    `INSERT OR REPLACE INTO messages (id, chat_jid, sender, sender_name, content, timestamp, is_from_me) VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    message.message_id,
    chatJid,
    sender.sender_id.user_id || sender.sender_id.open_id || 'unknown',
    resolvedName || sender.sender_id.user_id || 'Unknown',
    fullContent,
    timestamp,
    isFromMe ? 1 : 0,
  );
}

export function storeFeishuMessageEvent(
  event: { message: FeishuMessage; sender: FeishuSender },
  chatJid: string,
  isFromMe: boolean,
  resolvedName?: string,
): void {
  storeFeishuMessage(
    event.message,
    event.sender,
    chatJid,
    isFromMe,
    resolvedName,
  );
}

export function getChat(
  chatJid: string,
): { jid: string; name: string; last_message_time: string } | null {
  const row = db
    .prepare(`SELECT jid, name, last_message_time FROM chats WHERE jid = ?`)
    .get(chatJid) as
    | { jid: string; name: string; last_message_time: string }
    | undefined;
  return row || null;
}
```

### Step 3: Create `src/channels/feishu.ts`

```typescript
import * as Lark from '@larksuiteoapi/node-sdk';
import fs from 'fs';
import path from 'path';

import { STORE_DIR } from '../config.js';
import {
  storeChatMetadata,
  storeFeishuMessageEvent,
  FeishuMessage,
  FeishuSender,
} from '../db.js';
import { logger } from '../logger.js';
import {
  Channel,
  NewMessage,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

interface FeishuCredentials {
  appId: string;
  appSecret: string;
  encryptKey?: string;
  verificationToken?: string;
}

interface FeishuChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: (chatJid: string, timestamp: string, name?: string) => void;
  registeredGroups: () => Record<string, RegisteredGroup>;
  onRealtimeMessage?: (msg: NewMessage) => Promise<void>;
}

export class FeishuChannel implements Channel {
  name = 'feishu';
  prefixAssistantName = false;

  private client: Lark.Client | null = null;
  private wsClient: Lark.WSClient | null = null;
  private eventDispatcher: Lark.EventDispatcher | null = null;
  private storeDir: string;
  private registeredGroups: () => Record<string, RegisteredGroup>;
  private onMessageCallback: OnInboundMessage;
  private onRealtimeMessage?: (msg: NewMessage) => Promise<void>;
  private credentials: FeishuCredentials | null = null;
  private botOpenId: string | null = null;
  private connected = false;
  private statusMessageIds: Record<string, Record<string, string>> = {};
  private accumulatedStatusMessages: Record<string, Record<string, string>> =
    {};

  constructor(opts: FeishuChannelOpts) {
    this.storeDir = path.join(STORE_DIR, 'auth');
    this.registeredGroups = opts.registeredGroups;
    this.onMessageCallback = opts.onMessage;
    this.onRealtimeMessage = opts.onRealtimeMessage;
  }

  async connect(): Promise<void> {
    const credsPath = path.join(this.storeDir, 'feishu-credentials.json');

    if (!fs.existsSync(credsPath)) {
      const msg =
        'Feishu credentials not found. Run npm run auth:feishu first.';
      logger.error(msg);
      throw new Error(msg);
    }

    try {
      this.credentials = JSON.parse(fs.readFileSync(credsPath, 'utf-8'));
    } catch {
      throw new Error('Invalid Feishu credentials file');
    }

    if (!this.credentials?.appId || !this.credentials?.appSecret) {
      throw new Error('Feishu credentials missing appId or appSecret');
    }

    this.client = new Lark.Client({
      appId: this.credentials.appId,
      appSecret: this.credentials.appSecret,
      appType: Lark.AppType.SelfBuild,
    });

    // Verify connection
    try {
      const response = await (
        this.client as unknown as {
          request: (opts: { method: string; url: string }) => Promise<{
            code: number;
            bot?: { bot_name?: string; open_id?: string };
          }>;
        }
      ).request({
        method: 'GET',
        url: '/open-apis/bot/v3/info',
      });
      if (response.code === 0 && response.bot) {
        this.botOpenId = response.bot.open_id || null;
        logger.info({ botName: response.bot.bot_name }, 'Connected to Feishu');
      }
    } catch (err) {
      logger.error({ err }, 'Failed to verify Feishu connection');
      throw err;
    }

    await this.setupWebSocket();
    this.connected = true;
  }

  private async setupWebSocket(): Promise<void> {
    if (!this.credentials) return;

    this.wsClient = new Lark.WSClient({
      appId: this.credentials.appId,
      appSecret: this.credentials.appSecret,
      loggerLevel: Lark.LoggerLevel.info,
    });

    this.eventDispatcher = new Lark.EventDispatcher({
      encryptKey: this.credentials.encryptKey,
      verificationToken: this.credentials.verificationToken,
    });

    this.eventDispatcher.register({
      'im.message.receive_v1': async (data) => {
        try {
          await this.handleMessageEvent(
            data as unknown as { message: FeishuMessage; sender: FeishuSender },
          );
        } catch (err) {
          logger.error({ err }, 'Error handling Feishu message');
        }
      },
      'im.chat.member.bot.added_v1': async (data) => {
        logger.info(
          { chatId: (data as { chat_id?: string }).chat_id },
          'Bot added to chat',
        );
      },
      'im.chat.member.bot.deleted_v1': async (data) => {
        logger.info(
          { chatId: (data as { chat_id?: string }).chat_id },
          'Bot removed from chat',
        );
      },
    });

    return new Promise((resolve, reject) => {
      try {
        this.wsClient!.start({ eventDispatcher: this.eventDispatcher! });
        logger.info('Feishu WebSocket client started');
        resolve();
      } catch (err) {
        reject(err);
      }
    });
  }

  private async handleMessageEvent(event: {
    message: FeishuMessage;
    sender: FeishuSender;
  }): Promise<void> {
    const chatId = event.message.chat_id;
    const senderOpenId = event.sender.sender_id.open_id;
    const senderUserId = event.sender.sender_id.user_id;

    if (senderOpenId === this.botOpenId || senderUserId === this.botOpenId)
      return;

    if (!chatId.startsWith('oc_') && !chatId.startsWith('ou_')) return;

    const chatType = event.message.chat_type === 'p2p' ? 'private' : 'group';
    const timestamp = event.message.create_time
      ? new Date(parseInt(event.message.create_time, 10)).toISOString()
      : new Date().toISOString();

    const senderName = await this.resolveSenderName(senderOpenId || '');
    const chatName = await this.getChatName(chatId);

    storeChatMetadata(chatId, timestamp, chatName);

    if (this.registeredGroups()[chatId]) {
      storeFeishuMessageEvent(event, chatId, false, senderName);
    }

    const { content, mediaInfo } = this.parseMessageContent(
      event.message.content,
      event.message.message_type,
    );
    let msgContent = mediaInfo ? `${content} ${mediaInfo}` : content;

    const trimmedContent = msgContent.trim().toLowerCase();
    if (
      trimmedContent === 'register' ||
      trimmedContent.startsWith('register ')
    ) {
      msgContent = '/' + msgContent;
    }

    const newMessage: NewMessage = {
      id: event.message.message_id,
      chat_jid: chatId,
      sender: senderOpenId || 'unknown',
      sender_name: senderName,
      content: msgContent,
      timestamp,
      chat_type: chatType,
    };

    await this.onMessageCallback(chatId, newMessage);

    if (this.onRealtimeMessage) {
      await this.onRealtimeMessage(newMessage);
    }
  }

  private parseMessageContent(
    content: string,
    messageType: string,
  ): { content: string; mediaInfo?: string } {
    try {
      const parsed = JSON.parse(content);
      switch (messageType) {
        case 'text':
          return { content: parsed.text || '' };
        case 'post':
          return { content: '[Rich Text]' };
        case 'image':
          return { content: '<media:image>', mediaInfo: 'image' };
        case 'file':
          return { content: '<media:document>', mediaInfo: 'file' };
        case 'audio':
          return { content: '<media:audio>', mediaInfo: 'audio' };
        case 'video':
          return { content: '<media:video>', mediaInfo: 'video' };
        case 'sticker':
          return { content: '<media:sticker>', mediaInfo: 'sticker' };
        default:
          return { content: `[${messageType}]` };
      }
    } catch {
      return { content };
    }
  }

  private async resolveSenderName(openId: string): Promise<string> {
    if (!this.client || !openId) return 'Unknown';
    try {
      const res = await this.client.contact.user.get({
        path: { user_id: openId },
        params: { user_id_type: 'open_id' },
      });
      return res.data?.user?.name || res.data?.user?.en_name || openId;
    } catch {
      return openId;
    }
  }

  private async getChatName(chatId: string): Promise<string> {
    if (!this.client) return chatId;
    try {
      const res = await this.client.im.chat.get({ path: { chat_id: chatId } });
      return res.data?.name || chatId;
    } catch {
      return chatId;
    }
  }

  async sendMessage(jid: string, text: string): Promise<void> {
    if (!this.client || (!jid.startsWith('oc_') && !jid.startsWith('ou_')))
      return;

    const receiveIdType = jid.startsWith('oc_') ? 'chat_id' : 'open_id';
    const content = JSON.stringify({
      zh_cn: { content: [[{ tag: 'md', text }]] },
    });

    try {
      const response = await this.client.im.message.create({
        params: { receive_id_type: receiveIdType },
        data: { receive_id: jid, content, msg_type: 'post' },
      });
      if (response.code !== 0) throw new Error(response.msg);
      logger.info(
        { chatId: jid, messageId: response.data?.message_id },
        'Message sent',
      );
    } catch (err) {
      logger.error({ chatId: jid, err }, 'Failed to send message');
      throw err;
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  ownsJid(jid: string): boolean {
    return jid.startsWith('oc_') || jid.startsWith('ou_');
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    if (this.wsClient) {
      this.wsClient.close();
    }
  }

  async setTyping(_jid: string, _isTyping: boolean): Promise<void> {
    // Feishu doesn't support typing indicators via API
  }
}
```

### Step 4: Create `src/feishu-auth.ts`

```typescript
import fs from 'fs';
import path from 'path';
import readline from 'readline';
import * as Lark from '@larksuiteoapi/node-sdk';

const STORE_DIR = path.join(process.cwd(), 'store', 'auth');
const CREDS_PATH = path.join(STORE_DIR, 'feishu-credentials.json');

interface FeishuCredentials {
  appId: string;
  appSecret: string;
  encryptKey?: string;
  verificationToken?: string;
}

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
});

function ask(question: string): Promise<string> {
  return new Promise((resolve) =>
    rl.question(question, (a) => resolve(a.trim())),
  );
}

async function testConnection(
  creds: FeishuCredentials,
): Promise<{ success: boolean; botName?: string; error?: string }> {
  try {
    const client = new Lark.Client({
      appId: creds.appId,
      appSecret: creds.appSecret,
      appType: Lark.AppType.SelfBuild,
    });
    const response = await (
      client as unknown as {
        request: (opts: { method: string; url: string }) => Promise<{
          code: number;
          msg?: string;
          bot?: { bot_name?: string };
        }>;
      }
    ).request({
      method: 'GET',
      url: '/open-apis/bot/v3/info',
    });
    if (response.code === 0 && response.bot) {
      return { success: true, botName: response.bot.bot_name };
    }
    return { success: false, error: response.msg || `code ${response.code}` };
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function main(): Promise<void> {
  console.log('╔════════════════════════════════════════════════════╗');
  console.log('║     Feishu (Lark) Bot Authentication Setup       ║');
  console.log('╚════════════════════════════════════════════════════╝\n');

  if (fs.existsSync(CREDS_PATH)) {
    try {
      const existing = JSON.parse(fs.readFileSync(CREDS_PATH, 'utf-8'));
      console.log('⚠️  Existing credentials found.');
      const overwrite = await ask('Overwrite? (y/N): ');
      if (overwrite.toLowerCase() !== 'y') {
        console.log('Keeping existing credentials.');
        rl.close();
        return;
      }
    } catch {
      // continue
    }
  }

  console.log('Enter your Feishu app credentials:\n');

  const appId = await ask('App ID: ');
  if (!appId) {
    console.error('❌ App ID required');
    rl.close();
    process.exit(1);
  }

  const appSecret = await ask('App Secret: ');
  if (!appSecret) {
    console.error('❌ App Secret required');
    rl.close();
    process.exit(1);
  }

  const encryptKey = await ask('Encrypt Key (optional): ');
  const verificationToken = await ask('Verification Token (optional): ');

  const creds: FeishuCredentials = {
    appId,
    appSecret,
    ...(encryptKey && { encryptKey }),
    ...(verificationToken && { verificationToken }),
  };

  console.log('\n🔄 Testing connection...');
  const result = await testConnection(creds);

  if (!result.success) {
    console.error('❌ Connection failed:', result.error);
    rl.close();
    process.exit(1);
  }

  console.log(`✅ Connected! Bot: ${result.botName}`);

  fs.mkdirSync(STORE_DIR, { recursive: true });
  fs.writeFileSync(CREDS_PATH, JSON.stringify(creds, null, 2));
  fs.chmodSync(CREDS_PATH, 0o600);

  console.log(`\n✅ Credentials saved to: ${CREDS_PATH}`);
  console.log('\nNext: Set MESSENGER=feishu in .env and run npm run dev\n');

  rl.close();
}

main().catch((err) => {
  console.error('Error:', err);
  process.exit(1);
});
```

### Step 5: Update `src/index.ts`

Key changes:

```typescript
import { FeishuChannel } from './channels/feishu.js';

const MESSENGER_TYPE =
  (process.env.MESSENGER as 'whatsapp' | 'telegram' | 'feishu') || 'whatsapp';

let whatsapp: WhatsAppChannel;
let feishu: FeishuChannel;
let channel: Channel | undefined;

// Add Feishu helper functions
function getExistingMainSession(): string | undefined {
  return Object.entries(registeredGroups).find(
    ([, g]) => g.folder === MAIN_GROUP_FOLDER || g.isMainSession === true,
  )?.[0];
}

async function handleRegisterCommand(
  chatJid: string,
  senderName: string,
  folderName?: string,
  chatType?: 'private' | 'group',
  senderId?: string,
): Promise<string> {
  if (registeredGroups[chatJid]) {
    return `✅ Already registered as **${registeredGroups[chatJid].name}**`;
  }

  const chatInfo = getChat(chatJid);
  const displayName = chatInfo?.name || senderName || 'Chat';

  let folder: string;
  let isMain = false;

  if (folderName) {
    folder = folderName;
  } else if (chatType === 'private') {
    const existing = getExistingMainSession();
    if (existing) {
      folder = chatInfo?.name
        ? chatInfo.name.replace(/[^a-z0-9-]/gi, '-')
        : `p2p-${Date.now()}`;
    } else {
      folder = MAIN_GROUP_FOLDER;
      isMain = true;
    }
  } else {
    folder = chatInfo?.name
      ? chatInfo.name.replace(/[^a-z0-9-]/gi, '-')
      : `chat-${Date.now()}`;
  }

  const trigger = isMain || chatType === 'private' ? '' : '';

  registerGroup(chatJid, {
    name: displayName,
    folder: folder.replace(/[^a-z0-9-]/gi, '-'),
    trigger,
    requiresTrigger: !isMain && chatType !== 'private',
    added_at: new Date().toISOString(),
    allowedUsers: chatType === 'private' && senderId ? [senderId] : undefined,
    isMainSession: isMain,
  });

  return isMain
    ? `✅ **Main Session Registered!**\n\nName: **${displayName}**\nFolder: ${folder}`
    : `✅ **Workspace Registered!**\n\nName: **${displayName}**\nFolder: ${folder}`;
}

async function handleRealtimeMessage(msg: NewMessage): Promise<void> {
  const group = registeredGroups[msg.chat_jid];
  const content = msg.content.trim();
  const lowerContent = content.toLowerCase();

  if (lowerContent === '/register' || lowerContent.startsWith('/register ')) {
    const folderName = lowerContent.startsWith('/register ')
      ? content.slice(9).trim()
      : undefined;
    const response = await handleRegisterCommand(
      msg.chat_jid,
      msg.sender_name,
      folderName,
      msg.chat_type,
      msg.sender,
    );
    await channel!.sendMessage(msg.chat_jid, response);
    lastAgentTimestamp[msg.chat_jid] = msg.timestamp;
    saveState();
    return;
  }

  if (!group) {
    await channel!.sendMessage(
      msg.chat_jid,
      `👋 Welcome!\n\nSend **/register** to register this chat.`,
    );
    return;
  }

  if (msg.chat_type === 'private' && group.allowedUsers?.length) {
    if (!group.allowedUsers.includes(msg.sender)) {
      await channel!.sendMessage(
        msg.chat_jid,
        '⛔ Not authorized for this session.',
      );
      return;
    }
  }

  queue.enqueueMessageCheck(msg.chat_jid);
}

// In main():
if (MESSENGER_TYPE === 'feishu') {
  feishu = new FeishuChannel({
    onMessage: (chatJid, msg) => storeMessage(msg),
    onChatMetadata: (chatJid, timestamp, name) =>
      storeChatMetadata(chatJid, timestamp, name),
    registeredGroups: () => registeredGroups,
    onRealtimeMessage: handleRealtimeMessage,
  });

  channel = feishu;
  logger.info('Using Feishu messenger');
  await feishu.connect();
} else {
  // WhatsApp initialization...
}
```

### Step 6: Update `src/package.json`

Add script:

```json
{
  "scripts": {
    "auth:feishu": "tsx src/feishu-auth.ts"
  }
}
```

### Step 7: Update `.env`

```bash
MESSENGER=feishu

# Sync to container
cp .env data/env/env
```

## Chat ID Formats

| Platform | Format                       | Example                       |
| -------- | ---------------------------- | ----------------------------- |
| WhatsApp | `@g.us` / `@s.whatsapp.net`  | `120363xxx@g.us`              |
| Feishu   | `oc_` (group) / `ou_` (user) | `oc_xxxxxxxx` / `ou_xxxxxxxx` |

## Testing

```bash
# 1. Authenticate
npm run auth:feishu

# 2. Start NanoClaw
MESSENGER=feishu npm run dev

# 3. In Feishu:
# - Add bot to a group or DM
# - Send /register to register
# - Send a message to test
```

## Troubleshooting

**Bot not receiving messages:**

- Check `MESSENGER=feishu` is set
- Verify credentials: `cat store/auth/feishu-credentials.json`
- Check WebSocket: `tail -f logs/nanoclaw.log | grep -i feishu`

**Registration issues:**

```bash
sqlite3 store/messages.db "SELECT * FROM registered_groups WHERE jid LIKE 'oc_%' OR jid LIKE 'ou_%'"
```

**WebSocket not connecting:**

- Verify event subscription is set to WebSocket mode
- Check app is published with active version
- Confirm credentials are correct

## Removal

To remove Feishu integration:

1. Delete `src/channels/feishu.ts`
2. Delete `src/feishu-auth.ts`
3. Remove Feishu code from `src/index.ts`
4. Remove `auth:feishu` from `package.json`
5. Remove Feishu registrations from SQLite
6. `npm uninstall @larksuiteoapi/node-sdk`
7. Rebuild and restart
