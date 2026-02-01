# Plan: `simon reboot` - UniFi PoE Device Reboot Command

## Steg 1: Förtydliga vad vi bygger

### Clarifying Questions
1. **Är detta en ny funktion eller en ändring i befintlig funktion?** - Ny funktion
2. **Vad är det förväntade resultatet när detta är klart?** - Ett kommando som låter användaren välja en eller flera datorer från en lista och sedan starta om dem via PoE-omstart
3. **Finns det några begränsningar jag bör känna till?** - Använder UniFi Controller API, behöver API-nyckel och controller-URL

## Steg 2: Samla Visuals

Inga visuals har tillhandahållits ännu.

## Steg 3: Identifiera Referensimplementationer

Befintlig kod att referera till:
- `scripts/talos.sh` - visar mönster för fzfSelect med multi-select
- `scripts/kubernetes.sh` - visar hur kommandon struktureras
- Huvudfilen `simon` - visar kommandorouting via case-satser

## Steg 4: Kontrollera Produktkontext

Ingen `agent-os/product/` mapp finns. Inga specifika produktmål att förhålla sig till.

## Steg 5: Yrka Relevanta Standarder

- `agent-os/standards/global/conventions.md` - Kodkonventioner
- `agent-os/standards/global/error-handling.md` - Felhantering
- Företagets egna mönster från befintliga kommandon

## Steg 6: Generera Spec-mappens Namn

```
2026-02-01-0900-unifi-reboot-command/
```

## Steg 7: Strukturera Planen

### Task 1: Spara spec-dokumentation
Spara detta dokument och relaterade filer i `agent-os/specs/2026-02-01-0900-unifi-reboot-command/`

### Task 2: Skapa `main_reboot` funktion
Implementera huvudfunktionen i ny fil `scripts/unifi.sh`:
- Funktion för att hämta alla UniFi-enheter från controller
- Filtrera för att visa endast PoE-anslutna datorer
- Använd fzf för multi-select

### Task 3: Implementera PoE Power Cycling
- Funktion för att slå av PoE på specifik port
- Funktion för att slå på PoE på specifik port
- Vänta-funktion mellan av/på

### Task 4: Integrera med huvudkommandot
- Lägg till `source "$SCRIPT_DIR/scripts/unifi.sh"` i `simon`
- Lägg till `reboot) main_reboot ;;` i case-satsen

### Task 5: Lägg till konfigurationshantering
- Spara UniFi controller URL och API-nyckel
- Använd 1Password eller miljövariabler för känslig data

## Steg 8: Komplettera Planen

### Implementation Tasks

| Task | Beskrivning | Status |
|------|-------------|--------|
| 1 | Spara spec-dokumentation | ✓ |
| 2 | Skapa main_reboot funktion med enhetslistning | Pending |
| 3 | Implementera PoE power cycling | Pending |
| 4 | Integrera med huvudkommandot | Pending |
| 5 | Lägg till konfigurationshantering | Pending |

### Teknisk Implementation

#### UniFi API Anrop
```bash
# Hämta enheter
curl -s -H "Authorization: Bearer $UNIFI_API_KEY" \
  "$UNIFI_CONTROLLER/api/s/default/stat/device" | jq '.'

# Slå av PoE
curl -s -X PUT \
  -H "Authorization: Bearer $UNIFI_API_KEY" \
  -H "Content-Type: application/json" \
  "$UNIFI_CONTROLLER/api/s/default/rest/device/$DEVICE_ID" \
  -d '{"port_overrides": [{"port_idx": $PORT, "poe_mode": "off"}]}'
```

#### Kommandoflow
1. Användaren kör `simon reboot`
2. Scriptet hämtar alla enheter från UniFi Controller
3. Visa lista med datorer (enheter med PoE-anslutning)
4. Användaren väljer en eller flera med fzf
5. För varje vald enhet:
   - Slå av PoE
   - Vänta 5 sekunder
   - Slå på PoE
6. Visa bekräftelse

### Fördjupade Frågor att Besvara

1. **Var lagras UniFi-inloggningsuppgifter?** - 1Password CLI (som andra kommandon i projektet)
2. **Vilka portar ska visas?** - Endast portar med anslutna enheter?
3. **Ska vi cacha enhetslistan?** - Ja, för snabbare visning
4. **Felscenario?** - Vad händer om enheten inte svarar?
