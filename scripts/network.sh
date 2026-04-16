#!/bin/bash

main_trip() {
    local target="${1:-}"
    
    if [ -z "$target" ]; then
        echo "Usage: simon trip <target>"
        echo "Example: simon trip example.com"
        return 1
    fi
    
    if [ ! -f "$HOME/.cargo/bin/trip" ]; then
        echo "❌ trip saknas, installera med: cargo install trip --locked"
        return 1
    fi
    
    local trip_cmd="$HOME/.cargo/bin/trip"
    
    if [ "$(uname)" = "Linux" ]; then
        getcap "$trip_cmd" | grep -q "cap_net_raw" || {
            echo "⚠️ Sätter CAP_NET_RAW capability på trip..."
            sudo setcap CAP_NET_RAW+p "$trip_cmd"
        }
    fi
    
    "$trip_cmd" "$target"
}