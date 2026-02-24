# Intent: src/config.ts modifications

## What changed
Added Feishu credentials to config.ts, using environment variables via readEnvFile.

## Key sections

### New imports and envConfig
- Added: `FEISHU_APP_ID`, `FEISHU_APP_SECRET` to readEnvFile array

### New exports
- Added: `FEISHU_APP_ID` - Feishu app ID from .env
- Added: `FEISHU_APP_SECRET` - Feishu app secret from .env
