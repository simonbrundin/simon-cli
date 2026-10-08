#!/bin/bash

# Converted from coding.nu

main_dev() {
	# Delegate to devenv/dev.sh
	exec /home/simon/repos/devenv/dev.sh
}

main_devpod_delete() {
	selectedDevpod=$(devpod list | tail -n +4 | awk -F'|' '{print $1}' | tr -d ' ' | fzf)
	devpod delete "$selectedDevpod"
}

main_login_vault() {
	password=$(bw get password a2041c06-1cb1-4eb5-a609-b35300c9d21a)
	vault login -method=userpass username=simonbrundin password="$password"
}

main_test() {
	local package_json package_dir package_manager manager status
	local failed=0
	local -a package_jsons=()

	while IFS= read -r -d '' package_json; do
		package_jsons+=("$package_json")
	done < <(find . -type f -name "package.json" -not -path "*/node_modules/*" -print0 2>/dev/null)

	for package_json in "${package_jsons[@]}"; do
		package_dir=$(dirname "$package_json")
		package_manager=""
		if command -v jq >/dev/null 2>&1; then
			package_manager=$(jq -r '.packageManager // ""' "$package_json" 2>/dev/null) || {
				echo "❌ Kan inte läsa packageManager från $package_json" >&2
				failed=1
				continue
			}
		fi
		manager="${package_manager%%@*}"

		echo "🧪 Tester: $package_dir (${manager:-bun})"
		(
			cd "$package_dir" || exit 1
			case "$manager" in
				""|bun) bun test ;;
				npm) npm test ;;
				pnpm) pnpm test ;;
				yarn) yarn test ;;
				*) echo "❌ Ej stödd package manager: $package_manager" >&2; exit 1 ;;
			esac
		)
		status=$?
		if [ "$status" -ne 0 ]; then
			echo "❌ Tester misslyckades: $package_dir" >&2
			failed=1
		fi
	done

	return "$failed"
}

main_commit() {
	if ! main_test; then
		echo "❌ Commit avbruten eftersom minst en testkörning misslyckades." >&2
		return 1
	fi

	local git_status_before git_status_after
	git_status_before=$(git status)
	lazygit
	git_status_after=$(git status)
	if [ "$git_status_before" != "$git_status_after" ]; then
		xdg-open "https://argoworkflows.simonbrundin.com/workflows/?limit=5&Contains=commit"
	fi
}

# Helper function to find tmux pane for a project
_find_tmux_pane_for_project() {
	local project_name="$1"
	
	# Try to find a tmux session with the project name
	if tmux has-session -t "$project_name" 2>/dev/null; then
		# Try window named "dev"
		if tmux list-windows -t "$project_name" 2>/dev/null | grep -q "dev"; then
			local window_index=$(tmux list-windows -t "$project_name" 2>/dev/null | grep "dev" | head -1 | cut -d: -f1)
			if [ -n "$window_index" ]; then
				echo "$project_name:$window_index"
				return 0
			fi
		fi
		# Fall back to first window
		echo "$project_name:1"
		return 0
	fi
	
	# Try to find pane with matching simon process
	for bash_pid in $(ps -eo pid,ppid,comm 2>/dev/null | grep -E "bash|zsh" | awk '{print $1}'); do
		local cwd=$(readlink /proc/$bash_pid/cwd 2>/dev/null)
		if echo "$cwd" | grep -q "/$project_name/"; then
			# Match this bash to a tmux pane
			for pane in $(tmux list-panes -a -F '#{session_name}|#{window_index}|#{pane_pid}' 2>/dev/null); do
				local pane_pid=$(echo "$pane" | cut -d'|' -f3)
				if [ "$pane_pid" = "$bash_pid" ]; then
					local session=$(echo "$pane" | cut -d'|' -f1)
					local window=$(echo "$pane" | cut -d'|' -f2)
					echo "$session:$window"
					return 0
				fi
			done
		fi
	done
	
	return 1
}

main_tilt_restart() {
	# Find project root (where .git lives)
	local current_dir="$PWD"
	local root_dir=""

	while [ "$current_dir" != "/" ]; do
		if [ "$current_dir" = "$HOME" ]; then
			break
		fi
		if [ -d "$current_dir/.git" ] || [ -f "$current_dir/.git" ]; then
			root_dir="$current_dir"
			break
		fi
		current_dir="$(dirname "$current_dir")"
	done

	if [ -z "$root_dir" ]; then
		echo "❌ Not in a git project (no .git directory/file found)"
		return 1
	fi

	local dev_dir="$root_dir/environments/dev"

	if [ ! -d "$dev_dir" ]; then
		echo "❌ Directory not found: $dev_dir"
		return 1
	fi

	# Find Tiltfile location (from template repo)
	local template_tiltfile="/home/simon/repos/repo-template/environments/dev/Tiltfile"
	if [ ! -f "$template_tiltfile" ]; then
		template_tiltfile="/home/simon/repos/repo-template/dev/Tiltfile"
	fi
	if [ ! -f "$template_tiltfile" ]; then
		echo "❌ Ingen Tiltfile hittad i mall-repo: /home/simon/repos/repo-template"
		return 1
	fi

	# Copy tilt.yaml from template if not exists locally
	local template_tiltyaml="/home/simon/repos/repo-template/environments/dev/tilt.yaml"
	if [ ! -f "$template_tiltyaml" ]; then
		template_tiltyaml="/home/simon/repos/repo-template/dev/tilt.yaml"
	fi
	if [ -f "$template_tiltyaml" ] && [ ! -f "$dev_dir/tilt.yaml" ]; then
		echo "📋 Kopierar tilt.yaml från mallen..."
		cp "$template_tiltyaml" "$dev_dir/tilt.yaml"
	fi

	# Generate unique port based on project name + branch
	local project_name=$(basename "$root_dir")
	local branch=$(git -C "$root_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
	local port_offset=$(echo "$project_name$branch" | cksum | awk '{print $1 % 100}')
	local tilt_port=$((10350 + port_offset))

	# Generate Kind cluster name and ensure it exists
	# Replace / with - to handle branch names like feature/test
	branch=$(echo "$branch" | tr '/' '-')
	local cluster_name="$project_name.$branch"

	if ! kind get clusters 2>/dev/null | grep -q "^$cluster_name$"; then
		echo "🔧 Skapar Kind-kluster: $cluster_name"
		kind create cluster --name "$cluster_name" --wait 5m
	fi

	# Switch kubeconfig to Kind cluster
	kind export kubeconfig --name "$cluster_name"

	# Find tilt processes running in this project's dev_dir
	local tilt_pid=""
	for pid in $(pgrep -d' ' -f "tilt up"); do
		local cwd
		cwd=$(readlink /proc/$pid/cwd 2>/dev/null)
		if [ "$cwd" = "$dev_dir" ]; then
			tilt_pid="$pid"
			break
		fi
	done

	if [ -n "$tilt_pid" ]; then
		echo "🔄 Restartar Tilt i befintlig process (PID: $tilt_pid)..."
		
		# Send SIGINT to gracefully stop tilt
		kill -INT "$tilt_pid" 2>/dev/null
		
		# Wait for tilt to stop (max 5 seconds)
		for i in {1..10}; do
			if ! kill -0 "$tilt_pid" 2>/dev/null; then
				break
			fi
			sleep 0.5
		done
		
		# Force kill if still running
		if kill -0 "$tilt_pid" 2>/dev/null; then
			kill -9 "$tilt_pid" 2>/dev/null
			sleep 1
		fi
	fi

	# Find tmux pane for this project
	local tmux_target=""
	tmux_target=$(_find_tmux_pane_for_project "$project_name")
	
	if [ -n "$tmux_target" ]; then
		echo "📺 Skickar 'simon dev' till tmux: $tmux_target"
		tmux send-keys -t "$tmux_target" "simon dev" C-m
	else
		# No tmux found, start in background
		echo "🚀 Ingen tmux hittades, startar Tilt i bakgrunden..."
		cd "$dev_dir" || return 1
		nohup bash -c "TILT_PORT=$tilt_port TILT_LOCAL_ROOT=$dev_dir TILT_REPO_NAME=$project_name TILT_BRANCH=$branch TILT_PORT_OFFSET=$port_offset tilt up -f '$template_tiltfile'" > /dev/null 2>&1 &
	fi

	echo "✅ Tilt omstartad på port $tilt_port"
	echo "📝 Loggar: tilt logs --port=$tilt_port"
}
