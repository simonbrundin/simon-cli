# Shaping Notes: `simon reboot` Command

## Scope

### In Scope
- Lista alla datorer anslutna till UniFi PoE-switch
- Multi-select interface via fzf
- cykla PoE-ström (off → wait → on) för valda enheter
- Tydlig feedback till användaren
- Felhantering för vanliga fel

### Out of Scope
- Hantera andra enheter än datorer (servrar, IoT, etc.)
- Schemalagd omstart
- Reboot via SSH/WOL
- Konfiguration av switchar

## Design Decisions

| Beslut | Motivering |
|--------|------------|
| Använd UniFi Controller API | Standard sätt att hantera UniFi-nätverk |
| fzf för interaktiv selection | Konsistent med resten av CLI:t |
| 5 sekunder wait-tid | Tillräckligt för strömcykel, inte för långt |
| 1Password för credentials | Följer befintliga mönster i projektet |
| Egen script-fil (unifi.sh) | Separerar concerns, som andra domänspecifika scripts |

## Context

### Användarens Behov
- Snabbt sätt att starta om datorer utan fysisk åtkomst
- Enkel interaktion via CLI
- Kunna välja flera datorer samtidigt
- Visuell bekräftelse på att åtgärden lyckats

### Teknisk Kontext
- Befintlig Bash-baserad CLI med fzf
- UniFi Controller kräver API-nyckel
- PoE-styrning sker per port på switchen

## Öppna Frågor

1. **Hur identifierar vi "datorer" vs andra enheter?** - Alla enheter på US 48 PoE 500W visas, användaren väljer
2. **Ska vi spara config i en fil?** - Ja, via 1Password CLI
3. **Ska vi visa switch-namn?** - Ja
4. **Wait-tid?** - 5 sekunder (standard)
