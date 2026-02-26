# Per-Group Skills

Enable different groups to use different skills.

## Directory Structure

```
container/skills/
├── agent-browser/        # Global skill (available to all groups)
├── custom-skill-a/       # Global skill
├── main/                 # Skills only for 'main' group
│   └── my-skill/
└── test/                 # Skills only for 'test' group
    └── another-skill/
```

## How It Works

- **Global skills**: Put in root of `container/skills/` - all groups will load them
- **Group-specific skills**: Put in subdirectory named after the group's folder (e.g., `main/`, `test/`)

## Usage

After applying this skill:

1. Restart the nanoclaw service
2. Add skills to `container/skills/` for global availability
3. Add skills to `container/skills/{group-folder}/` for group-specific availability
