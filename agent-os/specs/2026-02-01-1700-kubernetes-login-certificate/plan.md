# Plan: Fixa `simon kubernetes login certificate` utan service account

## Steg 1: Förtydliga Scope

- **Nuvarande beteende:** Funktionen försöker först använda `OP_SERVICE_ACCOUNT_TOKEN`, sedan `op signin --raw`, men misslyckas ofta med ett missvisande felmeddelande
- **Önskat beteende:** Funktionen ska fungera med vanlig 1Password-inloggning (biometri/PIN/lösenord) utan att kräva service account
- **Inga visuella referenser**

## Steg 2: Referens-implementationer

- `scripts/unifi.sh:13` - Använder `op signin --raw` direkt med session-fil
- `scripts/talos.sh:42` - Liknande mönster för 1Password-autentisering

## Steg 3: Produkt-kontext

Finns i `agent-os/` - inga specifika produktrelaterade constraints identifierade.

## Steg 4: Relevanta Standards

- `agent-os/standards/global/conventions.md` - Miljövariabler och konfiguration

## Steg 5: Planering

### Task 1: Spara spec-dokumentation
Spara denna plan och relaterade filer i `agent-os/specs/2026-02-01-1700-kubernetes-login-certificate/`

### Task 2: Analysera nuvarande implementation
Granska `scripts/kubernetes.sh:10-88` för att identifiera exakt var autentiseringslogiken brister.

### Task 3: Fixa autentiseringsflödet
Modifiera `main_kubernetes_login_certificate()` för att:
1. Först försöka med `op signin --raw` (standard 1Password-inloggning)
2. Använda befintlig session från `~/.op/session` om tillgänglig
3. Endast använda `OP_SERVICE_ACCOUNT_TOKEN` som fallback
4. Förbättra felmeddelanden för att guida användaren korrekt

### Task 4: Testa ändringarna
Kör `simon kubernetes login certificate` och verifiera att det fungerar med vanlig 1Password-inloggning.

## Output Structure

```
agent-os/specs/2026-02-01-1700-kubernetes-login-certificate/
├── plan.md           # Denna plan
├── shape.md          # Shaping-beslut och kontext
├── standards.md      # Relevanta standarder
└── references.md     # Pekare till liknande kod
```
