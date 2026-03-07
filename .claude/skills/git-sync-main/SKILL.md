---
name: git-sync-main
description: Sync local-dev with upstream main. Triggers on "sync branches", "rebase local-dev", "sync with upstream", "git sync".
---

# Git Sync Main

Sync local-dev branch with origin/main and keep origin/local in sync.

## Branch Strategy
- `origin/local`: Stable branch (synced before rebase)
- `origin/local-dev`: Development branch
- `origin/main`: Upstream/fork parent branch

## Steps

### 1. Fetch Latest
```bash
git fetch origin
```

### 2. Sync origin/local
```bash
git push origin origin/local-dev:local --force
```
Force push local-dev to origin/local to keep stable branch in sync.

### 2.1. Sync local branch
```bash
git fetch origin
git checkout local
git reset --hard origin/local
```
Ensure local local branch matches origin/local.

### 3. Rebase local-dev onto origin/main
```bash
git checkout local-dev
git rebase origin/main
```

### 4. Auto-Resolve Conflicts

**Check for conflicts first:**
```bash
git status --porcelain
```
If no conflicts → continue to step 5.

**If conflicts exist:**
- **Lock files** (package-lock.json):
  - If deleted in local-dev but modified in origin/main → accept deletion (`git rm <file>`)
  - Otherwise use local-dev: `git checkout --theirs <file>`

- **Config files** (tsconfig.json, .eslintrc, etc.) → use origin/main: `git checkout --ours <file>`

- **Code conflicts** (core principle: prefer origin/main):
  - Use origin/main: `git checkout --ours <file>`
  - local-dev changes deferred, will be re-implemented on top of main
  - This keeps architecture aligned with upstream, avoiding diverging

Then: `git add . && git rebase --continue`

### 5. Verify Build
```bash
npm run build
```
- If build passes, check if local-dev features are intact:
  - Feishu health check
  - ETF assistant
  - skill-tester
  - per-group-skills
- If features are broken by conflicts, fix according to origin/main architecture
- Re-run build to verify

### 6. Push to Remote
```bash
git push origin local-dev --force-with-lease
```
Force push without merge commits.

### 7. Summary
- Show rebase result
- List new features gained from origin/main
