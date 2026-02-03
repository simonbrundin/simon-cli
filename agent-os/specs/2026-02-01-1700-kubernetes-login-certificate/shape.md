# Shaping: `kubernetes login certificate` utan service account

## Problem

`main_kubernetes_login_certificate()` i `scripts/kubernetes.sh:10-88` har följande problem:

1. **Fel ordning:** Försöker använda `OP_SERVICE_ACCOUNT_TOKEN` först (rad 17-19)
2. **Bristande session-hantering:** Kontrollerar inte befintlig `~/.op/session`-fil
3. **Förvirrande felmeddelande:** Uppmuntrar användaren att använda service account istället för vanlig inloggning

## Beslut

### Autentiserings-prioritet

```
1. Använd befintlig ~/.op/session om den finns och är giltig
2. Kör op signin --raw för att skapa ny session
3. Använd OP_SERVICE_ACCOUNT_TOKEN som sista fallback
```

### Beteende

- **Om 1Password är olåst:** `op signin --raw` returnerar en session-token direkt
- **Om 1Password är låst:** Scriptet ska be användaren låsa upp 1Password
- **Service account:** Ska endast användas i CI/CD eller headless-miljöer

## Kontext

Referens från `scripts/unifi.sh:11-13`:
```bash
mkdir -p ~/.op
chmod 700 ~/.op
op signin --raw > ~/.op/session 2>/dev/null
```

Detta mönster bör återanvändas i `main_kubernetes_login_certificate()`.
