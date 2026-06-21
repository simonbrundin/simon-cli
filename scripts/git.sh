#!/bin/bash

main_push() {
	local changes
	changes=$(git status --short)

	if [ -z "$changes" ]; then
		echo "⚠️ Inga ändringar att commit/pusha"
		return 0
	fi

	echo "📋 Analyserar ändringar..."
	git status --short
	echo ""

	local files
	files=$(git diff --name-only HEAD)

	if [ -z "$files" ]; then
		files=$(git status --porcelain | awk '{print $2}')
	fi

	declare -A categories
	categories=(
		[feat]=""
		[fix]=""
		[refactor]=""
		[docs]=""
		[chore]=""
		[style]=""
		[test]=""
	)

	local untracked_files=$(git status --porcelain | grep "^??" | awk '{print $2}')

	while IFS= read -r file; do
		[ -z "$file" ] && continue

		local ext="${file##*.}"
		local basename=$(basename "$file")
		local dirname=$(dirname "$file")

		case "$ext" in
		vue | ts | tsx | js | jsx)
			categories[feat]="${categories[feat]}\n$file"
			;;
		py)
			if echo "$file" | grep -qiE "(fix|bug|error|patch|hack)"; then
				categories[fix]="${categories[fix]}\n$file"
			else
				categories[refactor]="${categories[refactor]}\n$file"
			fi
			;;
		patch)
			categories[fix]="${categories[fix]}\n$file"
			;;
		md | rst | txt)
			categories[docs]="${categories[docs]}\n$file"
			;;
		json | yaml | yml | toml | env | gitignore | ini | conf)
			categories[chore]="${categories[chore]}\n$file"
			;;
		css | scss | sass | less)
			categories[style]="${categories[style]}\n$file"
			;;
		*)
			if echo "$basename" | grep -qE "(\.test\.|\.spec\.|^test\.|\.spec\.)"; then
				categories[test]="${categories[test]}\n$file"
			elif echo "$dirname" | grep -qE "(^test/|/tests?/)"; then
				categories[test]="${categories[test]}\n$file"
			elif echo "$file" | grep -qiE "(refactor|restructure)"; then
				categories[refactor]="${categories[refactor]}\n$file"
			else
				categories[refactor]="${categories[refactor]}\n$file"
			fi
			;;
		esac
	done <<<"$files"

	while IFS= read -r file; do
		[ -z "$file" ] && continue
		categories[feat]="${categories[feat]}\n$file"
	done <<<"$untracked_files"

	echo "📊 Kategorisering:"
	local total_files=0
	for type in feat fix refactor docs chore style test; do
		local count=$(echo -e "${categories[$type]}" | grep -v '^$' | wc -l)
		if [ $count -gt 0 ]; then
			echo "   $type: $count fil(er)"
			total_files=$((total_files + count))
		fi
	done
	echo ""

	local commit_count=0
	local commit_messages=()

	for type in feat fix refactor docs chore style test; do
		local files_in_cat="${categories[$type]}"
		[ -z "$files_in_cat" ] && continue

		local file_list=$(echo -e "$files_in_cat" | grep -v '^$' | sort -u | tr '\n' ' ')
		git add $file_list

		local count=$(echo -e "$files_in_cat" | grep -v '^$' | wc -l)

		local first_files=$(echo "$file_list" | cut -d' ' -f1-3 | tr ' ' ', ')
		if [ $count -gt 3 ]; then
			local msg="$type: $first_files (+$((count - 3)) more)"
		else
			local msg="$type: $first_files"
		fi

		if git commit -m "$msg" 2>/dev/null; then
			commit_count=$((commit_count + 1))
			commit_messages+=("$msg")
			echo "✅ Commit: $msg"
		fi
	done

	if [ $commit_count -eq 0 ]; then
		echo "⚠️ Inga nya commits att pusha"
		return 0
	fi

	echo ""
	echo "📤 Pushar till remote..."
	if git push; then
		echo ""
		echo "═══════════════════════════════════════"
		echo "✅ Push lyckad!"
		echo "═══════════════════════════════════════"
		echo ""
		echo "📊 Sammanfattning:"
		echo "   • Filer kategoriserade: $total_files"
		echo "   • Commits skapade: $commit_count"
		echo ""
		echo "📝 Commit-meddelanden:"
		for msg in "${commit_messages[@]}"; do
			echo "   • $msg"
		done
	else
		echo "❌ Push misslyckades"
		return 1
	fi
}

main_new_worktree() {
	local name="$1"

	if [ -z "$name" ]; then
		echo "❌ Ange ett namn för worktree:"
		echo "   simon new worktree <namn>"
		echo "   simon nw <namn>"
		return 1
	fi

	# Check if inside a git repository
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "❌ Du måste vara i ett git-repository för att skapa en worktree"
		return 1
	fi

	# Get original repo name from remote (strips .git suffix)
	local original_repo
	original_repo=$(basename -s .git "$(git remote get-url origin)")

	# Create safe name (replace / and spaces with -)
	local safe_name="${name//\//-}"
	safe_name="${safe_name// /-}"

	# Create path: <repos_dir>/<original_repo>-<safe_name>
	local worktree_path="$HOME/repos/${original_repo}-${safe_name}"

	echo -e "\033[34m🌿 Skapar git worktree...\033[0m"
	echo "   Branch: $name"
	echo "   Path: $worktree_path"
	echo ""

	# Create the worktree with a new branch
	if git worktree add -b "$name" "$worktree_path"; then
		echo -e "\033[32m✅ Worktree skapad i $worktree_path\033[0m"
		cd "$worktree_path" || return 1
	else
		echo -e "\033[31m❌ Misslyckades att skapa worktree\033[0m"
		return 1
	fi
}

main_pr() {
	# 0. Hämta parent repo för att kunna navigera tillbaka
	local parent_repo
	parent_repo=$(basename -s .git "$(git remote get-url origin)" 2>/dev/null) || true

	# 1. Kontrollera att vi är i ett git repo
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "❌ Inte i ett git-repo"
		return 1
	fi

	# 2. Hämta branch
	local branch
	branch=$(git branch --show-current)

	if [ -z "$branch" ]; then
		echo "❌ Ingen branch detekterad"
		return 1
	fi

	echo "📦 Current branch: $branch"

	# 3. Kontrollera om det finns uncommitted changes
	if ! git diff --quiet || ! git diff --cached --quiet; then
		echo "❌ Du har ocommitade ändringar. Commit först."
		return 1
	fi

	# 4. Kontrollera om branch är pushad
	if ! git ls-remote --exit-code origin "$branch" >/dev/null 2>&1; then
		echo "🚀 Branch finns inte på remote. Pushar..."
		git push -u origin "$branch" || return 1
	else
		echo "✔ Branch finns redan på remote"
	fi

	# 5. Skapa PR
	echo "📝 Skapar PR..."
	gh pr create --fill --web

	# 6. Hitta worktree root och parent repo
	local root
	local parent_repo
	local current_dir
	root=$(git rev-parse --show-toplevel)
	parent_repo=$(basename -s .git "$(git remote get-url origin)")
	current_dir="$HOME/repos/$parent_repo"

	# 7. Navigera till parent repo först
	cd "$current_dir" || {
		echo "❌ Kunde inte navigera till $current_dir"
		return 1
	}

	# 8. Ta bort worktree om det finns
	if [ -d "$root" ]; then
		echo "🧹 Tar bort worktree: $root"
		git worktree remove "$root" --force
	else
		echo "🧹 Worktree finns redan inte: $root"
	fi

	echo "✅ Klart! Nu i: $current_dir"
}
