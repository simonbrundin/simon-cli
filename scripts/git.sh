#!/bin/bash

# Converted from git.nu

main_clone() {
    name="$1"
    git clone "git@github.com:simonbrundin/$name.git" "$HOME/repos/$name"
    repo_path="$HOME/repos/$name"
    if [ -d "$repo_path" ]; then
        cd "$repo_path"
    else
        echo "Failed to clone or directory not found: $repo_path"
    fi
}

main_push() {
    local changes
    changes=$(git status --short)

    if [ -z "$changes" ]; then
        echo "⚠️ Inga ändringar att commit/pusha"
        return 0
    fi

    echo "📋 Analyserar ändringar..."
    echo "$changes"
    echo ""

    local files
    files=$(git diff --name-only)

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

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        local ext="${file##*.}"
        local basename=$(basename "$file")

        case "$ext" in
            vue|ts|tsx)
                categories[feat]="${categories[feat]}\n$file"
                ;;
            py)
                if echo "$file" | grep -qiE "(fix|bug|error|patch)"; then
                    categories[fix]="${categories[fix]}\n$file"
                else
                    categories[refactor]="${categories[refactor]}\n$file"
                fi
                ;;
            md)
                categories[docs]="${categories[docs]}\n$file"
                ;;
            json|yaml|yml|toml|env|gitignore)
                categories[chore]="${categories[chore]}\n$file"
                ;;
            css|scss|sass|less)
                categories[style]="${categories[style]}\n$file"
                ;;
            *)
                if echo "$basename" | grep -qE "(\.test\.|\.spec\.|^test/|/tests/)"; then
                    categories[test]="${categories[test]}\n$file"
                elif echo "$file" | grep -qiE "(new|add|create)"; then
                    categories[feat]="${categories[feat]}\n$file"
                else
                    categories[refactor]="${categories[refactor]}\n$file"
                fi
                ;;
        esac
    done <<< "$files"

    local commit_count=0
    local commit_messages=()

    for type in feat fix refactor docs chore style test; do
        local files_in_cat="${categories[$type]}"
        [ -z "$files_in_cat" ] && continue

        local file_list=$(echo -e "$files_in_cat" | grep -v '^$' | sort -u | tr '\n' ' ')
        git add $file_list

        local count=$(echo -e "$files_in_cat" | grep -v '^$' | wc -l)
        local msg="$type: $(echo "$file_list" | cut -d' ' -f1-3)$([ $count -gt 3 ] && echo " (+$((count-3)) more)" || true)"

        git commit -m "$msg" 2>/dev/null && {
            commit_count=$((commit_count + 1))
            commit_messages+=("$msg")
            echo "✅ Commit: $msg"
        }
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
        echo "   • Filer kategoriserade: $(echo "$files" | wc -l)"
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