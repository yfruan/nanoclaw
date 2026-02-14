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
  onRealtimeMessage?: (msg: NewMessage) => Promise<void>; // For /register handling
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

    // Parse content and download image if present - WAIT for download to complete before triggering agent
    const { content, mediaInfo, imageKey, imageBase64 } =
      await this.parseMessageContent(
        event.message.content,
        event.message.message_type,
        event.message.message_id,
      );

    // Build message content
    let msgContent = mediaInfo ? `${content} ${mediaInfo}` : content;
    const trimmedContent = msgContent.trim().toLowerCase();
    if (
      trimmedContent === 'register' ||
      trimmedContent.startsWith('register ')
    ) {
      msgContent = '/' + msgContent;
    }

    // Only trigger message processing after image is downloaded (if present)
    // This ensures imageBase64 is available when the agent runs
    const newMessage: NewMessage = {
      id: event.message.message_id,
      chat_jid: chatId,
      sender: senderOpenId || 'unknown',
      sender_name: senderName,
      content: msgContent,
      timestamp,
      chat_type: chatType,
      imageBase64,
      imageKey,
    };

    await this.onMessageCallback(chatId, newMessage);

    // Also call realtime handler if registered (for /register handling)
    // Only call after image is downloaded to ensure imageBase64 is available
    if (this.onRealtimeMessage) {
      logger.info({ chatId, hasImage: !!imageBase64 }, 'Calling realtime handler');
      await this.onRealtimeMessage(newMessage);
    }
  }

  private async parseMessageContent(
    content: string,
    messageType: string,
    messageId?: string,
  ): Promise<{ content: string; mediaInfo?: string; imageKey?: string; imageBase64?: string }> {
    try {
      const parsed = JSON.parse(content);
      switch (messageType) {
        case 'text':
          return { content: parsed.text || '' };
        case 'post': {
          // Parse rich text post - extract text and images
          let text = parsed.title || '';
          let imageKey: string | undefined;
          let imageBase64: string | undefined;

          // Parse content array (2D array of elements)
          if (parsed.content && Array.isArray(parsed.content)) {
            for (const row of parsed.content) {
              if (Array.isArray(row)) {
                for (const elem of row) {
                  if (elem.tag === 'text' && elem.text) {
                    text += (text ? ' ' : '') + elem.text;
                  } else if (elem.tag === 'img' && elem.image_key && messageId) {
                    const key = elem.image_key as string;
                    imageKey = key;
                    // Download first image found
                    imageBase64 = await this.downloadImageAsBase64(key, messageId);
                  }
                }
              }
            }
          }

          if (imageKey) {
            return {
              content: text || '[Rich Text with image]',
              mediaInfo: 'image',
              imageKey,
              imageBase64,
            };
          }
          return { content: text || '[Rich Text]' };
        }
        case 'image': {
          const imageKey = parsed.image_key;
          if (imageKey && messageId) {
            // Download image and convert to base64 for vision
            const base64 = await this.downloadImageAsBase64(imageKey, messageId);
            return {
              content: '<media:image>',
              mediaInfo: 'image',
              imageKey,
              imageBase64: base64,
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

  private async downloadImageAsBase64(imageKey: string, messageId: string): Promise<string | undefined> {
    if (!this.client) return undefined;
    try {
      // Use message-resource API to download user-sent images
      // The imageKey from the message is used as file_key
      const res = await this.client.im.messageResource.get({
        params: { type: 'image' },
        path: { message_id: messageId, file_key: imageKey },
      });
      // Read stream and convert to base64
      const chunks: Buffer[] = [];
      const stream = res.getReadableStream();
      for await (const chunk of stream) {
        chunks.push(Buffer.from(chunk));
      }
      const buffer = Buffer.concat(chunks);
      const base64 = buffer.toString('base64');
      logger.info({ imageKey, messageId, size: buffer.length }, 'Feishu image downloaded');

      return base64;
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
