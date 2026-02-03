# Standards som appliceras

## Globala standards

### `agent-os/standards/global/conventions.md`

> **Environment Configuration:** Use environment variables for configuration; never commit secrets or API keys to version control.

- ✅ `OP_SERVICE_ACCOUNT_TOKEN` används som miljövariabel, aldrig hardkodad
- ✅ Kubeconfig lagras i temporär fil, inte i repo
- ⚠️  Felmeddelanden bör inte avslöja känslig information

## Tekniska krav

- Bash-kompatibilitet (scriptet körs i bash)
- 1Password CLI (`op`) måste vara installerad
- kubectl måste vara tillgänglig för att verifiera inloggning
