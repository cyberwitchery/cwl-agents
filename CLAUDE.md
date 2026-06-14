heartbeat — a cyclical autonomous agent that contributes to a GitHub org using Claude Code.

- config: `config.env` (copy `config.env.example` to get started)
- prompts use `${VARIABLE}` placeholders expanded by `envsubst` at runtime via `tick.sh`
- credentials (`.pem`, `*-app-id`, `*-installation-id`) and state files are gitignored
