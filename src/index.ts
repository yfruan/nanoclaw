import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import 'dotenv/config';

import {
  ASSISTANT_NAME,
  DATA_DIR,
  IDLE_TIMEOUT,
  MAIN_GROUP_FOLDER,
  POLL_INTERVAL,
  TRIGGER_PATTERN,
} from './config.js';
import { WhatsAppChannel } from './channels/whatsapp.js';
import { FeishuChannel } from './channels/feishu.js';
import {
  ContainerOutput,
  runContainerAgent,
  writeGroupsSnapshot,
  writeTasksSnapshot,
} from './container-runner.js';
import {
  getAllChats,
  getAllRegisteredGroups,
  getAllSessions,
  getAllTasks,
  getChat,
  getMessagesSince,
  getNewMessages,
  getRouterState,
  initDatabase,
  setRegisteredGroup,
  setRouterState,
  setSession,
  storeChatMetadata,
  storeMessage,
} from './db.js';
import { GroupQueue } from './group-queue.js';
import { startIpcWatcher } from './ipc.js';
import { formatMessages, formatOutbound } from './router.js';
import { startSchedulerLoop } from './task-scheduler.js';
import { Channel, NewMessage, RegisteredGroup } from './types.js';
import { logger } from './logger.js';

// Re-export for backwards compatibility during refactor
export { escapeXml, formatMessages } from './router.js';

let lastTimestamp = '';
let sessions: Record<string, string> = {};
let registeredGroups: Record<string, RegisteredGroup> = {};
let lastAgentTimestamp: Record<string, string> = {};
let messageLoopRunning = false;

const MESSENGER_TYPE =
  (process.env.MESSENGER as 'whatsapp' | 'telegram' | 'feishu') || 'whatsapp';

let whatsapp: WhatsAppChannel;
let feishu: FeishuChannel;
let channel: Channel | undefined;
const queue = new GroupQueue();

function loadState(): void {
  lastTimestamp = getRouterState('last_timestamp') || '';
  const agentTs = getRouterState('last_agent_timestamp');
  try {
    lastAgentTimestamp = agentTs ? JSON.parse(agentTs) : {};
  } catch {
    logger.warn('Corrupted last_agent_timestamp in DB, resetting');
    lastAgentTimestamp = {};
  }
  sessions = getAllSessions();
  registeredGroups = getAllRegisteredGroups();
  logger.info(
    { groupCount: Object.keys(registeredGroups).length },
    'State loaded',
  );
}

function saveState(): void {
  setRouterState('last_timestamp', lastTimestamp);
  setRouterState(
    'last_agent_timestamp',
    JSON.stringify(lastAgentTimestamp),
  );
}

function registerGroup(jid: string, group: RegisteredGroup): void {
  registeredGroups[jid] = group;
  setRegisteredGroup(jid, group);

  // Create group folder
  const groupDir = path.join(DATA_DIR, '..', 'groups', group.folder);
  fs.mkdirSync(path.join(groupDir, 'logs'), { recursive: true });

  logger.info(
    { jid, name: group.name, folder: group.folder },
    'Group registered',
  );
}

/**
 * Get available groups list for the agent.
 * Returns groups ordered by most recent activity.
 */
export function getAvailableGroups(): import('./container-runner.js').AvailableGroup[] {
  const chats = getAllChats();
  const registeredJids = new Set(Object.keys(registeredGroups));

  return chats
    .filter((c) => c.jid !== '__group_sync__' && c.jid.endsWith('@g.us'))
    .map((c) => ({
      jid: c.jid,
      name: c.name,
      lastActivity: c.last_message_time,
      isRegistered: registeredJids.has(c.jid),
    }));
}

/** @internal - exported for testing */
export function _setRegisteredGroups(groups: Record<string, RegisteredGroup>): void {
  registeredGroups = groups;
}

/**
 * Process all pending messages for a group.
 * Called by the GroupQueue when it's this group's turn.
 */
async function processGroupMessages(chatJid: string): Promise<boolean> {
  const group = registeredGroups[chatJid];
  if (!group) return true;

  const isMainGroup = group.folder === MAIN_GROUP_FOLDER;

  const sinceTimestamp = lastAgentTimestamp[chatJid] || '';
  const missedMessages = getMessagesSince(
    chatJid,
    sinceTimestamp,
    ASSISTANT_NAME,
  );

  if (missedMessages.length === 0) return true;

  // For non-main groups, check if trigger is required and present
  if (!isMainGroup && group.requiresTrigger !== false) {
    const hasTrigger = missedMessages.some((m) =>
      TRIGGER_PATTERN.test(m.content.trim()),
    );
    if (!hasTrigger) return true;
  }

  const prompt = formatMessages(missedMessages);

  // Extract imageBase64 from the latest message if present
  const latestMessage = missedMessages[missedMessages.length - 1];
  // Get imageBase64 from queue (set when message with image arrived)
  const imageBase64 = queue.getAndClearPendingImage(chatJid);

  // Advance cursor so the piping path in startMessageLoop won't re-fetch
  // these messages. Save the old cursor so we can roll back on error.
  const previousCursor = lastAgentTimestamp[chatJid] || '';
  lastAgentTimestamp[chatJid] =
    missedMessages[missedMessages.length - 1].timestamp;
  saveState();

  logger.info(
    { group: group.name, messageCount: missedMessages.length },
    'Processing messages',
  );

  // Track idle timer for closing stdin when agent is idle
  let idleTimer: ReturnType<typeof setTimeout> | null = null;

  const resetIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      logger.debug({ group: group.name }, 'Idle timeout, closing container stdin');
      queue.closeStdin(chatJid);
    }, IDLE_TIMEOUT);
  };

  // Set typing indicator if channel supports it
  if (channel?.setTyping) {
    await channel.setTyping(chatJid, true);
  }

  let hadError = false;
  let outputSentToUser = false;

  const output = await runAgent(group, prompt, chatJid, async (result) => {
    // Streaming output callback — called for each agent result
    if (result.result) {
      const raw = typeof result.result === 'string' ? result.result : JSON.stringify(result.result);
      // Strip <internal>...</internal> blocks — agent uses these for internal reasoning
      const text = raw.replace(/<internal>[\s\S]*?<\/internal>/g, '').trim();
      logger.info({ group: group.name }, `Agent output: ${raw.slice(0, 200)}`);
      if (text) {
        await channel!.sendMessage(chatJid, `${ASSISTANT_NAME}: ${text}`);
        outputSentToUser = true;
      }
      // Only reset idle timer on actual results, not session-update markers (result: null)
      resetIdleTimer();
    }

    if (result.status === 'error') {
      hadError = true;
    }
  }, imageBase64);

  // Stop typing indicator
  if (channel?.setTyping) {
    await channel.setTyping(chatJid, false);
  }
  if (idleTimer) clearTimeout(idleTimer);

  if (output === 'error' || hadError) {
    // If we already sent output to the user, don't roll back the cursor —
    // the user got their response and re-processing would send duplicates.
    if (outputSentToUser) {
      logger.warn({ group: group.name }, 'Agent error after output was sent, skipping cursor rollback to prevent duplicates');
      return true;
    }
    // Roll back cursor so retries can re-process these messages
    lastAgentTimestamp[chatJid] = previousCursor;
    saveState();
    logger.warn({ group: group.name }, 'Agent error, rolled back message cursor for retry');
    return false;
  }

  return true;
}

async function runAgent(
  group: RegisteredGroup,
  prompt: string,
  chatJid: string,
  onOutput?: (output: ContainerOutput) => Promise<void>,
  imageBase64?: string,
): Promise<'success' | 'error'> {
  const isMain = group.folder === MAIN_GROUP_FOLDER;
  const sessionId = sessions[group.folder];

  // Update tasks snapshot for container to read (filtered by group)
  const tasks = getAllTasks();
  writeTasksSnapshot(
    group.folder,
    isMain,
    tasks.map((t) => ({
      id: t.id,
      groupFolder: t.group_folder,
      prompt: t.prompt,
      schedule_type: t.schedule_type,
      schedule_value: t.schedule_value,
      status: t.status,
      next_run: t.next_run,
    })),
  );

  // Update available groups snapshot (main group only can see all groups)
  const availableGroups = getAvailableGroups();
  writeGroupsSnapshot(
    group.folder,
    isMain,
    availableGroups,
    new Set(Object.keys(registeredGroups)),
  );

  // Wrap onOutput to track session ID from streamed results
  const wrappedOnOutput = onOutput
    ? async (output: ContainerOutput) => {
        if (output.newSessionId) {
          sessions[group.folder] = output.newSessionId;
          setSession(group.folder, output.newSessionId);
        }
        await onOutput(output);
      }
    : undefined;

  try {
    const output = await runContainerAgent(
      group,
      {
        prompt,
        sessionId,
        groupFolder: group.folder,
        chatJid,
        isMain,
        imageBase64: imageBase64,
      },
      (proc, containerName) => queue.registerProcess(chatJid, proc, containerName, group.folder),
      wrappedOnOutput,
    );

    if (output.newSessionId) {
      sessions[group.folder] = output.newSessionId;
      setSession(group.folder, output.newSessionId);
    }

    if (output.status === 'error') {
      logger.error(
        { group: group.name, error: output.error },
        'Container agent error',
      );
      return 'error';
    }

    return 'success';
  } catch (err) {
    logger.error({ group: group.name, err }, 'Agent error');
    return 'error';
  }
}

async function startMessageLoop(): Promise<void> {
  if (messageLoopRunning) {
    logger.debug('Message loop already running, skipping duplicate start');
    return;
  }
  messageLoopRunning = true;

  logger.info(`NanoClaw running (trigger: @${ASSISTANT_NAME})`);

  while (true) {
    try {
      const jids = Object.keys(registeredGroups);
      const { messages, newTimestamp } = getNewMessages(
        jids,
        lastTimestamp,
        ASSISTANT_NAME,
      );

      if (messages.length > 0) {
        logger.info({ count: messages.length }, 'New messages');

        // Advance the "seen" cursor for all messages immediately
        lastTimestamp = newTimestamp;
        saveState();

        // Deduplicate by group
        const messagesByGroup = new Map<string, NewMessage[]>();
        for (const msg of messages) {
          const existing = messagesByGroup.get(msg.chat_jid);
          if (existing) {
            existing.push(msg);
          } else {
            messagesByGroup.set(msg.chat_jid, [msg]);
          }
        }

        for (const [chatJid, groupMessages] of messagesByGroup) {
          const group = registeredGroups[chatJid];
          if (!group) continue;

          const isMainGroup = group.folder === MAIN_GROUP_FOLDER;
          const needsTrigger = !isMainGroup && group.requiresTrigger !== false;

          // For non-main groups, only act on trigger messages.
          // Non-trigger messages accumulate in DB and get pulled as
          // context when a trigger eventually arrives.
          if (needsTrigger) {
            const hasTrigger = groupMessages.some((m) =>
              TRIGGER_PATTERN.test(m.content.trim()),
            );
            if (!hasTrigger) continue;
          }

          // Pull all messages since lastAgentTimestamp so non-trigger
          // context that accumulated between triggers is included.
          const allPending = getMessagesSince(
            chatJid,
            lastAgentTimestamp[chatJid] || '',
            ASSISTANT_NAME,
          );
          const messagesToSend =
            allPending.length > 0 ? allPending : groupMessages;
          const formatted = formatMessages(messagesToSend);

          if (queue.sendMessage(chatJid, formatted)) {
            logger.debug(
              { chatJid, count: messagesToSend.length },
              'Piped messages to active container',
            );
            lastAgentTimestamp[chatJid] =
              messagesToSend[messagesToSend.length - 1].timestamp;
            saveState();
          } else {
            // No active container — enqueue for a new one
            queue.enqueueMessageCheck(chatJid);
          }
        }
      }
    } catch (err) {
      logger.error({ err }, 'Error in message loop');
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL));
  }
}

/**
 * Startup recovery: check for unprocessed messages in registered groups.
 * Handles crash between advancing lastTimestamp and processing messages.
 */
function recoverPendingMessages(): void {
  for (const [chatJid, group] of Object.entries(registeredGroups)) {
    const sinceTimestamp = lastAgentTimestamp[chatJid] || '';
    const pending = getMessagesSince(chatJid, sinceTimestamp, ASSISTANT_NAME);
    if (pending.length > 0) {
      logger.info(
        { group: group.name, pendingCount: pending.length },
        'Recovery: found unprocessed messages',
      );
      queue.enqueueMessageCheck(chatJid);
    }
  }
}

function ensureContainerSystemRunning(): void {
  try {
    execSync('container system status', { stdio: 'pipe' });
    logger.debug('Apple Container system already running');
  } catch {
    logger.info('Starting Apple Container system...');
    try {
      execSync('container system start', { stdio: 'pipe', timeout: 30000 });
      logger.info('Apple Container system started');
    } catch (err) {
      logger.error({ err }, 'Failed to start Apple Container system');
      console.error(
        '\n╔════════════════════════════════════════════════════════════════╗',
      );
      console.error(
        '║  FATAL: Apple Container system failed to start                 ║',
      );
      console.error(
        '║                                                                ║',
      );
      console.error(
        '║  Agents cannot run without Apple Container. To fix:           ║',
      );
      console.error(
        '║  1. Install from: https://github.com/apple/container/releases ║',
      );
      console.error(
        '║  2. Run: container system start                               ║',
      );
      console.error(
        '║  3. Restart NanoClaw                                          ║',
      );
      console.error(
        '╚════════════════════════════════════════════════════════════════╝\n',
      );
      throw new Error('Apple Container system is required but failed to start');
    }
  }

  // Kill and clean up orphaned NanoClaw containers from previous runs
  try {
    const output = execSync('container ls --format json', {
      stdio: ['pipe', 'pipe', 'pipe'],
      encoding: 'utf-8',
    });
    const containers: { status: string; configuration: { id: string } }[] = JSON.parse(output || '[]');
    const orphans = containers
      .filter((c) => c.status === 'running' && c.configuration.id.startsWith('nanoclaw-'))
      .map((c) => c.configuration.id);
    for (const name of orphans) {
      try {
        execSync(`container stop ${name}`, { stdio: 'pipe' });
      } catch { /* already stopped */ }
    }
    if (orphans.length > 0) {
      logger.info({ count: orphans.length, names: orphans }, 'Stopped orphaned containers');
    }
  } catch (err) {
    logger.warn({ err }, 'Failed to clean up orphaned containers');
  }
}

// --- Feishu helper functions ---

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
  // Strip Feishu mention prefix (e.g., "@_user_1 ") before checking commands
  const content = msg.content.replace(/^@\S+\s+/, '').trim();
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

  // Store imageBase64 in queue for vision support
  if (msg.imageBase64) {
    queue.setPendingImage(msg.chat_jid, msg.imageBase64);
  }

  queue.enqueueMessageCheck(msg.chat_jid);
}

async function main(): Promise<void> {
  ensureContainerSystemRunning();
  initDatabase();
  logger.info('Database initialized');
  loadState();

  // Graceful shutdown handlers
  const shutdown = async (signal: string) => {
    logger.info({ signal }, 'Shutdown signal received');
    await queue.shutdown(10000);
    if (channel) {
      await channel.disconnect();
    }
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  if (MESSENGER_TYPE === 'feishu') {
    logger.info('Using Feishu messenger');
    feishu = new FeishuChannel({
      onMessage: (chatJid, msg) => storeMessage(msg),
      onChatMetadata: (chatJid, timestamp, name) =>
        storeChatMetadata(chatJid, timestamp, name),
      registeredGroups: () => registeredGroups,
      onRealtimeMessage: handleRealtimeMessage,
    });
    channel = feishu;
  } else {
    logger.info('Using WhatsApp messenger (default)');
    whatsapp = new WhatsAppChannel({
      onMessage: (chatJid, msg) => storeMessage(msg),
      onChatMetadata: (chatJid, timestamp) =>
        storeChatMetadata(chatJid, timestamp),
      registeredGroups: () => registeredGroups,
    });
    channel = whatsapp;
  }
  // Connect — resolves when first connected
  await channel.connect();

  // Start subsystems (independently of connection handler)
  const sendViaChannel = async (jid: string, rawText: string) => {
    const prefix = channel?.prefixAssistantName ? `${ASSISTANT_NAME}: ` : '';
    const text = prefix + rawText;
    await channel!.sendMessage(jid, text);
  };

  startSchedulerLoop({
    registeredGroups: () => registeredGroups,
    getSessions: () => sessions,
    queue,
    onProcess: (groupJid, proc, containerName, groupFolder) => queue.registerProcess(groupJid, proc, containerName, groupFolder),
    sendMessage: sendViaChannel,
  });

  startIpcWatcher({
    sendMessage: (jid, text) => channel!.sendMessage(jid, text),
    registeredGroups: () => registeredGroups,
    registerGroup,
    syncGroupMetadata:
      'syncGroupMetadata' in channel
        ? (force) => (channel as any).syncGroupMetadata(force)
        : async () => {},
    getAvailableGroups,
    writeGroupsSnapshot: (gf, im, ag, rj) => writeGroupsSnapshot(gf, im, ag, rj),
  });
  queue.setProcessMessagesFn(processGroupMessages);
  recoverPendingMessages();
  startMessageLoop();
}

// Guard: only run when executed directly, not when imported by tests
const isDirectRun =
  process.argv[1] &&
  new URL(import.meta.url).pathname === new URL(`file://${process.argv[1]}`).pathname;

if (isDirectRun) {
  main().catch((err) => {
    logger.error({ err }, 'Failed to start NanoClaw');
    process.exit(1);
  });
}
