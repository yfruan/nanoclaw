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
