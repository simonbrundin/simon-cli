# Referens-implementationer

## `scripts/unifi.sh:11-13`

```bash
mkdir -p ~/.op
chmod 700 ~/.op
op signin --raw > ~/.op/session 2>/dev/null
```

**Används för:** UniFi-reboot-funktionen
**Mönster:** Skapar 1Password-session med vanlig inloggning

## `scripts/talos.sh:42`

```bash
op signin --raw > ~/.op/session
```

**Används för:** Talos-kommandon
**Mönster:** Samma session-baserade autentisering

## `scripts/kubernetes.sh:17-40`

**Nuvarande implementation** (problem):
- Försöker `OP_SERVICE_ACCOUNT_TOKEN` först
- Försöker `op signin --raw` med retry-logik
- Bristande felhantering

## Relaterad dokumentation

- [1Password CLI signin](https://developer.1password.com/docs/cli/signin/)
- [Kubernetes kubeconfig](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
