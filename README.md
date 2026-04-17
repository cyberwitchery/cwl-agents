# Heartbeat

A cyclical autonomous agent that contributes to a GitHub org using [Claude Code](https://docs.anthropic.com/en/docs/claude-code). It runs several times per day, each cycle opening a small slate of PRs — 2 small, 2 medium, 1 large — then reviewing them.

## Architecture

```
cron (every 30min)
  └─ tick.sh
       ├─ usage check (optional, skip if burning too fast)
       ├─ heartbeat_prompt.md          orchestrator
       │    ├─ sync repos
       │    ├─ sweep for work
       │    └─ for each topic:
       │         └─ heartbeat_topic_prompt.md   worker (own session, 30min cap)
       ├─ reviewer_prompt.md           reviews the PRs just opened
       └─ release_check_prompt.md      (every N days) opens "Publish vX.Y.Z" issues
```

Each topic runs in its own Claude session so a runaway implementation can't take down the cycle.

## Setup

### 1. Create two GitHub Apps

You need two apps installed on your org:

**Heartbeat** (the contributor):
- Repository permissions: Contents (Read & Write), Pull requests (Read & Write), Issues (Read & Write), Workflows (Read & Write), Metadata (Read)

**Reviewer** (the reviewer):
- Repository permissions: Pull requests (Read & Write), Metadata (Read)

For each app, download the private key and note the App ID and Installation ID.

### 2. Configure

```bash
cp config.env.example config.env
# Edit config.env with your org, emails, paths, etc.
```

Place credential files in the same directory as the prompts (`$HEARTBEAT_HOME`):

```
heartbeat-app.pem
heartbeat-app-id           # just the number, e.g. 12345
heartbeat-installation-id  # just the number
reviewer-app.pem
reviewer-app-id
reviewer-installation-id
```

### 3. Clone your org's repos

```bash
mkdir -p "$WORKSPACE"
gh repo list "$GITHUB_ORG" --limit 50 --json name -q '.[].name' | while read -r repo; do
    gh repo clone "$GITHUB_ORG/$repo" "$WORKSPACE/$repo"
done
```

The heartbeat agent will keep these in sync on each cycle.

### 4. Set up cron

```cron
@reboot  /path/to/tick.sh
*/30 * * * * /path/to/tick.sh
```

If your usage check command needs access to a keyring or session bus, export `DBUS_SESSION_BUS_ADDRESS` above the cron entries.

### 5. Email (optional)

If `NOTIFY_TO` is set in `config.env`, the reviewer sends a summary email via `msmtp` after each cycle. Configure `~/.msmtprc` with your SMTP provider.

## Files

| File | Purpose |
|------|---------|
| `tick.sh` | Cron entry point — decides when to run, invokes agents |
| `get-github-app-token` | Mints short-lived GitHub App installation tokens |
| `heartbeat_prompt.md` | Orchestrator: syncs repos, picks topics, spawns workers |
| `heartbeat_topic_prompt.md` | Worker: implements one topic, opens/updates a PR |
| `reviewer_prompt.md` | Reviewer: diffs each PR, leaves a verdict, sends email |
| `release_check_prompt.md` | Release checker: opens "Publish vX.Y.Z" issues |
| `config.env.example` | Template for all configuration |
| `config.env` | Your actual config (gitignored) |

## Usage check

The optional `USAGE_CHECK_CMD` in `config.env` lets you gate cycles on API usage. The command should print a number to stdout. If the number exceeds `PACE_THRESHOLD`, the cycle is skipped and rescheduled 1 hour out. This is useful for staying within rate limits on plans with usage caps.

## License

MIT
