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
            vue|ts|tsx|js|jsx)
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
            md|rst|txt)
                categories[docs]="${categories[docs]}\n$file"
                ;;
            json|yaml|yml|toml|env|gitignore|ini|conf)
                categories[chore]="${categories[chore]}\n$file"
                ;;
            css|scss|sass|less)
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
    done <<< "$files"

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        categories[feat]="${categories[feat]}\n$file"
    done <<< "$untracked_files"

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
            local msg="$type: $first_files (+$((count-3)) more)"
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