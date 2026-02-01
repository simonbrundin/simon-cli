# Reference Implementations

## Internal References

### `scripts/talos.sh`
**Relevans:** Hög - Visar mönster för interaktiv multi-select

```bash
# Multi-select med fzf (rad 28-29)
echo -e "\033[34mVilka noder vill du uppdatera?\033[0m"
selectedNodes=$(fzfSelect "$nodes")
```

**Lärdomar:**
- Använd `fzfSelect` direkt
- Acceptera space-separerad output för multi-select
- Konvertera till komma-separerad sträng för vidare bearbetning

### `scripts/talos.sh` - main_talos_update_config
**Relevans:** Medel - Visar mönster för API-anrop med auth

```bash
# 1Password-signin och läsa secrets (rad 40-44)
mkdir -p ~/.op
chmod 700 ~/.op
op signin --raw > ~/.op/session
op read op://talos/secrets/secrets.yaml -o secrets.yaml -f
```

**Lärdomar:**
- Använd 1Password CLI för känsliga uppgifter
- Spara session-token temporärt
- Städning efter användning

### `functions.sh`
**Relevans:** Hög - `fzfSelect` funktionen vi ska använda

```bash
fzfSelect() {
    local list=("$@")
    local selection
    selection=$(printf '%s\n' "${list[@]}" | fzf --multi)
    result=$(echo "$selection" | tr '\n' ' ' | sed 's/ $//')
    echo "$result"
}
```

### `simon` - main()
**Relevans:** Medel - Hur kommandon registreras

```bash
# Dynamisk kommandolista (rad 37-42)
for func in $(declare -F | awk '{print $3}' | grep '^main_' | grep -v '^main$'); do
    cmd=$(echo "$func" | sed 's/^main_//' | tr '_' ' ')
    commands+=("$cmd")
done
```

**Lärdomar:**
- Nya `main_*` funktioner auto-discoveras
- Kommandon läggs till genom att lägga till source-rad i `simon`
- Case-sats för subkommandon

## External References

### UniFi Network API Documentation
**URL:** https://github.com/Art-of-WiFi/UniFi-API-client

**Relevans:** Hög - Referens för API-anrop

Key endpoints:
- `GET /api/s/default/stat/device` - Lista alla enheter
- `PUT /api/s/default/rest/device/{id}` - Uppdatera enhet (för PoE-styrning)

### PoE Mode Values
- `auto` - PoE på, automatisk detektering
- `off` - PoE av
- `pasv24v` - Passive 24V
- `4pair` - 4-pair PoE

## Code Patterns to Follow

### Error Handling Pattern
```bash
if [ -z "$selected" ]; then
    echo "❌ Inget val gjort"
    return 1
fi
```

### API Call Pattern
```bash
response=$(curl -s -H "Authorization: Bearer $API_KEY" \
  "$CONTROLLER/api/endpoint")

if [ $? -ne 0 ]; then
    echo "❌ Kunde inte ansluta till UniFi Controller"
    return 1
fi
```

### Colored Output Pattern
```bash
echo -e "\033[34mInfo text\033[0m"    # Blå
echo -e "\033[32mFramgång\033[0m"      # Grön
echo -e "\033[31mFel text\033[0m"      # Röd
```
