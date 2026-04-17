Heartbeat — a cyclical autonomous agent that contributes to a GitHub org using Claude Code.

- Config: `config.env` (copy `config.env.example` to get started)
- Prompts use `${VARIABLE}` placeholders expanded by `envsubst` at runtime via `tick.sh`
- Credentials (`.pem`, `*-app-id`, `*-installation-id`) and state files are gitignored
