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

main_kill() {
	local port="${1:-}"

	if [ -z "$port" ]; then
		echo "Usage: simon kill <port>"
		echo "Example: simon kill 3000"
		return 1
	fi

	if ! [[ "$port" =~ ^[0-9]+$ ]]; then
		echo "❌ Fel: Ange ett giltigt portnummer"
		return 1
	fi

	local pid
	pid=$(lsof -ti ":$port" 2>/dev/null)

	if [ -z "$pid" ]; then
		echo "❌ Ingenting kör på port $port"
		return 1
	fi

	local process_name
	process_name=$(ps -p "$pid" -o comm= 2>/dev/null)

	echo -e "\033[34m🔪 Dödar process på port $port...\033[0m"
	echo "  Process: $process_name (PID: $pid)"

	kill "$pid" 2>/dev/null

	sleep 0.5

	if kill -0 "$pid" 2>/dev/null; then
		echo "  Processen svarade inte, tvingar..."
		kill -9 "$pid" 2>/dev/null
	fi

	if kill -0 "$pid" 2>/dev/null; then
		echo "❌ Kunde inte döda processen"
		return 1
	fi

	echo -e "\033[32m✅ Process $process_name (PID: $pid) avslutad\033[0m"
}
