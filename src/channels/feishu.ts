import * as Lark from '@larksuiteoapi/node-sdk';
import fs from 'fs';
import path from 'path';

import { ASSISTANT_NAME, DATA_DIR, FEISHU_APP_ID, FEISHU_APP_SECRET } from '../config.js';
import { storeChatMetadata, storeMessageDirect } from '../db.js';
import { logger } from '../logger.js';

// --- Feishu-specific types ---

interface FeishuSender {
  sender_id: { open_id?: string; user_id?: string; union_id?: string };
}

interface FeishuMessage {
  message_id: string;
  chat_id: string;
  chat_type: 'p2p' | 'group';
  message_type: string;
  content: string;
  create_time?: string;
  mentions?: Array<{ id: { open_id?: string }; name: string }>;
}
import {
  Channel,
  NewMessage,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

interface FeishuChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: (chatJid: string, timestamp: string, name?: string) => void;
  registeredGroups: () => Record<string, RegisteredGroup>;
  onRealtimeMessage?: (msg: NewMessage) => Promise<void>; // For /register handling
}

/**
 * Ensure message content has trigger word (@${ASSISTANT_NAME}) if bot is mentioned.
 */
function ensureTriggerWord(content: string, hasMention: boolean): string {
  if (hasMention && !content.toLowerCase().includes(`@${ASSISTANT_NAME}`)) {
    return `@${ASSISTANT_NAME} ` + content.trim();
  }
  return content;
}

export class FeishuChannel implements Channel {
  name = 'feishu';
  prefixAssistantName = false;

  private client: Lark.Client | null = null;
  private wsClient: Lark.WSClient | null = null;
  private registeredGroups: () => Record<string, RegisteredGroup>;
  private onMessageCallback: OnInboundMessage;
  private onRealtimeMessage?: (msg: NewMessage) => Promise<void>;
  private botOpenId: string | null = null;
  private connected = false;

  constructor(opts: FeishuChannelOpts) {
    this.registeredGroups = opts.registeredGroups;
    this.onMessageCallback = opts.onMessage;
    this.onRealtimeMessage = opts.onRealtimeMessage;
  }

  async connect(): Promise<void> {
    if (!FEISHU_APP_ID || !FEISHU_APP_SECRET) {
      const msg =
        'Feishu credentials not found. Set FEISHU_APP_ID and FEISHU_APP_SECRET in .env';
      logger.error(msg);
      throw new Error(msg);
    }

    this.client = new Lark.Client({
      appId: FEISHU_APP_ID,
      appSecret: FEISHU_APP_SECRET,
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
    this.wsClient = new Lark.WSClient({
      appId: FEISHU_APP_ID,
      appSecret: FEISHU_APP_SECRET,
      loggerLevel: Lark.LoggerLevel.info,
    });

    const eventDispatcher = new Lark.EventDispatcher({});

    eventDispatcher.register({
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
        this.wsClient!.start({ eventDispatcher });
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

    // Check for @mentions in the message - if present and content is empty, add trigger word
    // This handles Feishu @mentions which appear in the mentions array, not in content
    const mentionsBot =
      event.message.mentions?.some(
        (m) => m.id?.open_id === this.botOpenId || m.name?.toLowerCase() === ASSISTANT_NAME.toLowerCase(),
      ) ?? false;

    // Get group folder for IPC image storage
    const registeredGroup = this.registeredGroups()[chatId];
    const groupFolder = registeredGroup?.folder || 'main';

    // Parse content and download image if present - MUST wait for download to complete
    // BEFORE storing message in DB (which triggers the polling loop)
    const { content, mediaInfo, imagePath } =
      await this.parseMessageContent(
        event.message.content,
        event.message.message_type,
        event.message.message_id,
        groupFolder,
      );

    // Build message content - add image_path tag if image was saved
    let msgContent = mediaInfo ? `${content} ${mediaInfo}` : content;
    if (imagePath) {
      msgContent = `${msgContent}\n\n<image_path>${imagePath}</image_path>`;
      // For fin-assistant group, add trigger keyword to activate skill when only image is sent
      const isImageOnly = content?.trim() === '<media:image>' || content?.trim() === 'image' || !content?.trim();
      if (groupFolder === 'fin-assistant' && isImageOnly) {
        // Add trigger keyword to activate etf-assistant skill and explicit instruction to save
        msgContent = `<image_path>${imagePath}</image_path>\n\n请使用 etf-assistant skill 识别这张图片，提取基金代码、持有份额和成本单价，然后调用 'etf-assistant add <基金代码> <份额> <成本价> -s' 命令将识别结果保存到 portfolio.json`;
      }
    }

    // Check for /register command - handle it directly and return early
    const originalTrimmedContent = content.trim().toLowerCase();
    const isRegisterCommand = originalTrimmedContent.includes('/register');

    if (isRegisterCommand) {
      // Extract folder name if present (e.g., "@_user_1 /register FinAssistant" -> "/register FinAssistant")
      const match = originalTrimmedContent.match(/\/register\s*(.+)?$/);
      const folderName = match?.[1]?.trim();
      const registerContent = folderName ? `/register ${folderName}` : '/register';

      // Call realtime handler to process registration
      if (this.onRealtimeMessage) {
        await this.onRealtimeMessage({
          id: event.message.message_id,
          chat_jid: chatId,
          sender: senderOpenId || 'unknown',
          sender_name: senderName,
          content: registerContent,
          timestamp,
          chat_type: chatType,
        });
      }
      return; // Done, don't process further
    }

    // Normal message handling - ensure trigger word for @mentions
    msgContent = ensureTriggerWord(msgContent, mentionsBot);

    // Store message for registered groups
    if (this.registeredGroups()[chatId]) {
      storeFeishuMessageEvent(event, chatId, false, senderName);
    }

    // Build and send message to agent
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

    // Also call realtime handler if registered (for /register handling)
    // Only call after image is downloaded to ensure imagePath is available
    if (this.onRealtimeMessage) {
      logger.info({ chatId, hasImage: !!imagePath }, 'Calling realtime handler');
      await this.onRealtimeMessage(newMessage);
    }
  }

  private async parseMessageContent(
    content: string,
    messageType: string,
    messageId?: string,
    groupFolder?: string,
  ): Promise<{ content: string; mediaInfo?: string; imagePath?: string }> {
    try {
      const parsed = JSON.parse(content);
      switch (messageType) {
        case 'text':
          return { content: parsed.text || '' };
        case 'post': {
          // Parse rich text post - extract text, images, and @mentions
          let text = parsed.title || '';
          let imagePath: string | undefined;
          let hasMention = false;

          // Parse content array (2D array of elements)
          if (parsed.content && Array.isArray(parsed.content)) {
            for (const row of parsed.content) {
              if (Array.isArray(row)) {
                for (const elem of row) {
                  if (elem.tag === 'text' && elem.text) {
                    text += (text ? ' ' : '') + elem.text;
                  } else if (elem.tag === 'img' && elem.image_key && messageId && groupFolder) {
                    const key = elem.image_key as string;
                    // Download and save first image found to file
                    imagePath = await this.downloadAndSaveImage(key, messageId, groupFolder);
                  } else if (elem.tag === 'at' && elem.user_id) {
                    // Handle @mention - mark that we have a mention
                    hasMention = true;
                  }
                }
              }
            }
          }

          if (imagePath) {
            return {
              content: text || '[Rich Text with image]',
              mediaInfo: 'image',
              imagePath,
            };
          }

          // If there's a mention but no text, add a placeholder so trigger detection works
          if (hasMention && !text.trim()) {
            text = '@${ASSISTANT_NAME}';
          }

          return { content: text || '[Rich Text]' };
        }
        case 'image': {
          const imageKey = parsed.image_key;
          if (imageKey && messageId && groupFolder) {
            // Download image and save to file for vision
            const imagePath = await this.downloadAndSaveImage(imageKey, messageId, groupFolder);
            return {
              content: '<media:image>',
              mediaInfo: 'image',
              imagePath,
            };
          }
          return { content: '<media:image>', mediaInfo: 'image' };
        }
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

  private async downloadAndSaveImage(imageKey: string, messageId: string, groupFolder: string): Promise<string | undefined> {
    if (!this.client) return undefined;
    try {
      // Use message-resource API to download user-sent images
      // The imageKey from the message is used as file_key
      const res = await this.client.im.messageResource.get({
        params: { type: 'image' },
        path: { message_id: messageId, file_key: imageKey },
      });
      // Read stream and convert to buffer
      const chunks: Buffer[] = [];
      const stream = res.getReadableStream();
      for await (const chunk of stream) {
        chunks.push(Buffer.from(chunk));
      }
      const buffer = Buffer.concat(chunks);

      // Save to IPC images directory
      const imageDir = path.join(DATA_DIR, 'ipc', groupFolder, 'images');
      fs.mkdirSync(imageDir, { recursive: true });
      const imageFilename = `image-${Date.now()}-${Math.random().toString(36).slice(2, 6)}.jpg`;
      const imagePath = path.join(imageDir, imageFilename);
      fs.writeFileSync(imagePath, buffer);

      // Return container path (will be mounted at /workspace/ipc)
      const containerImagePath = `/workspace/ipc/${groupFolder}/images/${imageFilename}`;
      logger.info({ imageKey, messageId, size: buffer.length, imagePath: containerImagePath }, 'Feishu image saved to file');

      return containerImagePath;
    } catch (err) {
      logger.error({ imageKey, messageId, err }, 'Failed to download Feishu image');
    }
    return undefined;
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

// --- Feishu-specific database functions ---

function storeFeishuMessage(
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

  storeMessageDirect({
    id: message.message_id,
    chat_jid: chatJid,
    sender: sender.sender_id.user_id || sender.sender_id.open_id || 'unknown',
    sender_name: resolvedName || sender.sender_id.user_id || 'Unknown',
    content: fullContent,
    timestamp,
    is_from_me: isFromMe,
  });
}

function storeFeishuMessageEvent(
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
