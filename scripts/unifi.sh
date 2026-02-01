#!/bin/bash

main_reboot() {
    local unifi_controller="https://10.1.1.1"
    local unifi_api_key response clients devices selected switch_name mac
    local device_id device_name port_idx

    echo -e "\033[34m🔌 UniFi PoE Reboot\033[0m"
    echo ""

    mkdir -p ~/.op
    chmod 700 ~/.op
    op signin --raw > ~/.op/session 2>/dev/null

    unifi_api_key=$(op read "op://Private/Ubiquiti/API-key local" 2>/dev/null)

    if [ -z "$unifi_api_key" ]; then
        echo -e "\033[31m❌ Kunde inte hämta lokal API-nyckel från 1Password\033[0m"
        rm -f ~/.op/session
        return 1
    fi

    echo -e "\033[34m🌐 Hämtar enheter från UniFi...\033[0m"

    response=$(curl -s -k -X GET "${unifi_controller}/proxy/network/api/s/default/stat/device" \
        -H "X-API-Key: $unifi_api_key" \
        -H "Accept: application/json" 2>/dev/null)

    clients=$(curl -s -k -X GET "${unifi_controller}/proxy/network/api/s/default/stat/sta" \
        -H "X-API-Key: $unifi_api_key" \
        -H "Accept: application/json" 2>/dev/null)

    if [ $? -ne 0 ] || ! echo "$response" | jq -e '.data' >/dev/null 2>&1; then
        echo -e "\033[31m❌ Kunde inte ansluta till UniFi\033[0m"
        rm -f ~/.op/session
        return 1
    fi

    switch_name="US 48 PoE 500W"

    device_id=$(echo "$response" | jq -r ".data[] | select(.model | contains(\"US48P500\")) | ._id")
    mac=$(echo "$response" | jq -r ".data[] | select(.model | contains(\"US48P500\")) | .mac")

    devices=""
    for port in $(echo "$response" | jq -r ".data[] | select(._id == \"$device_id\") | .port_table[] | select(.port_idx > 0) | .port_idx"); do
        port_name=$(echo "$response" | jq -r ".data[] | select(._id == \"$device_id\") | .port_table[] | select(.port_idx == $port) | .name")
        client_names=$(echo "$clients" | jq -r ".data[] | select(.sw_port == $port and .name != null) | .name" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

        if [ -n "$client_names" ]; then
            devices="${devices}${port_name} - ${client_names} - Port ${port}\n"
        else
            devices="${devices}${port_name} - Tom - Port ${port}\n"
        fi
    done

    if [ -z "$devices" ]; then
        echo -e "\033[31m❌ Inga portar hittade på $switch_name\033[0m"
        rm -f ~/.op/session
        return 1
    fi

    echo ""
    echo -e "\033[34m📋 Välj enheter att starta om på $switch_name:\033[0m"
    selected=$(printf '%b' "$devices" | fzf --multi --height=30 --prompt="Välj enheter> ")

    if [ -z "$selected" ]; then
        echo "❌ Inget val gjort"
        rm -f ~/.op/session
        return
    fi

    echo -e "\033[34m🔄 Startar om valda enheter...\033[0m"

    echo "$selected" | while IFS= read -r line; do
        port_idx=$(echo "$line" | sed -n 's/.*Port \([0-9]*\).*/\1/p')
        device_name=$(echo "$line" | sed 's/ - Port.*//')

        echo -e "\033[34m  → Stänger av PoE på $device_name (Port $port_idx)...\033[0m"

        curl -s -k -X PUT \
            "${unifi_controller}/proxy/network/api/s/default/rest/device/$device_id" \
            -H "X-API-Key: $unifi_api_key" \
            -H "Content-Type: application/json" \
            -d "{\"port_overrides\": [{\"port_idx\": $port_idx, \"poe_mode\": \"off\"}]}" >/dev/null

        sleep 60

        echo -e "\033[34m  → Slår på PoE på $device_name (Port $port_idx)...\033[0m"

        curl -s -k -X PUT \
            "${unifi_controller}/proxy/network/api/s/default/rest/device/$device_id" \
            -H "X-API-Key: $unifi_api_key" \
            -H "Content-Type: application/json" \
            -d "{\"port_overrides\": [{\"port_idx\": $port_idx, \"poe_mode\": \"auto\"}]}" >/dev/null

        sleep 60

        echo -e "\033[32m  ✓ $device_name har startats om\033[0m"
    done

    rm -f ~/.op/session
    echo ""
    echo -e "\033[32m✅ Klart! Alla valda enheter har startats om.\033[0m"
}
