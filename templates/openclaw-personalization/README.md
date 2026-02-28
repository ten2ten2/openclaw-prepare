# OpenClaw Personalization Pack

This directory is an optional personalization source for `scripts/ubuntu/prep.sh`.

Import behavior:
- Import only runs when `OPENCLAW_IMPORT_PERSONALIZATION=1`.
- Files are copied directly into `OPENCLAW_OFFICIAL_HOME_DIR` (default: `/opt/openclaw/.openclaw`).
- No path mapping is applied.
- By default `OPENCLAW_PERSONALIZATION_OVERWRITE=1`, so same-name files in target will be overridden.

You can place optional content here, including:
- JSON files (for example `openclaw.json`)
- Markdown notes
- `skills/`, `tools/`, `agents/` directories
