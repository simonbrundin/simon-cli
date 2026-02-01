# Applicable Standards

## From `agent-os/standards/global/conventions.md`

| Standard | How We Apply It |
|----------|-----------------|
| Consistent Project Structure | Skapar ny fil `scripts/unifi.sh` enligt befintligt mönster |
| Clear Documentation | Kommentarer i koden, denna spec |
| Environment Configuration | Använder 1Password CLI för credentials |
| Version Control | Commit med tydligt meddelande |

## From `agent-os/standards/global/error-handling.md`

| Standard | How We Apply It |
|----------|-----------------|
| User-Friendly Messages | Svenska felmeddelanden, tydliga instruktioner |
| Fail Fast and Explicitly | Validera input tidigt, ge tydliga fel |
| Graceful Degradation | Om en enhet misslyckas, fortsätt med andra |
| Clean Up Resources | Inga temporära filer att städa |

## Project Conventions (Implicit)

- Funktionsnamn: `main_reboot`, `main_unifi_*`
- Färgkodning: `\033[34m` för info, `\033[32m` för framgång, `\033[31m` för fel
- Använder `fzfSelect` för interaktiv selection
- Använder `echo -e` för färgad output
- Returnerar tidigt vid avbruten selection (tom sträng)

## Additional Standards Applied

- **Fail on unset variables**: `set -u` i funktioner där det är lämpligt
- **Local variables**: Använd `local` för variabler i funktioner
- **Quoting**: Quote variabler för att hantera spaces
- **Error exit codes**: Använd exit 1 vid fel, 0 vid framgång
