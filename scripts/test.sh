#!/bin/bash

# Test runner for monorepo/multi-project repos
# Usage: simon test [path]
#        simon test discover [path]

main_test() {
    local root_dir="${1:-.}"
    
    # Resolve to absolute path
    if [[ "$root_dir" != /* ]]; then
        root_dir="$(pwd)/$root_dir"
    fi
    
    echo "🔍 Scanning: $root_dir"
    echo ""
    
    local results=()
    local project_count=0
    
    # Find Go projects (with go.mod)
    while IFS= read -r -d '' go_mod; do
        local project_dir
        project_dir=$(dirname "$go_mod")
        local rel_path
        rel_path="${project_dir#$root_dir/}"
        
        # Skip vendor and node_modules
        [[ "$project_dir" == *"/vendor/"* ]] && continue
        
        ((project_count++))
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📦 $rel_path"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Find feature files (in features/ subdir or sibling features/ dir)
        local feature_dir=""
        local feature_count=0
        local implemented=0
        local todo=0
        local wip=0
        local bug=0
        
        if [ -d "$project_dir/features" ]; then
            feature_dir="$project_dir/features"
        elif [ -d "$root_dir/features" ]; then
            feature_dir="$root_dir/features"
        fi
        
        if [ -n "$feature_dir" ] && [ -d "$feature_dir" ]; then
            feature_count=$(find "$feature_dir" -name "*.feature" 2>/dev/null | wc -l | tr -d ' ')
            
            # Count tags across all feature files
            implemented=$(grep -r "^  @" "$feature_dir" 2>/dev/null | grep -c "@implemented" || echo "0")
            todo=$(grep -r "^  @" "$feature_dir" 2>/dev/null | grep -c "@todo" || echo "0")
            wip=$(grep -r "^  @" "$feature_dir" 2>/dev/null | grep -c "@wip" || echo "0")
            bug=$(grep -r "^  @" "$feature_dir" 2>/dev/null | grep -c "@bug" || echo "0")
        fi
        
        # Check for godog/BDD tests
        if [ -d "$project_dir/features_test" ]; then
            echo "   Framework: godog (BDD)"
            echo "   Features:  $feature_count files | ✅$implemented implemented | 📋$todo todo | 🔧$wip wip | 🐛$bug bug"
            echo -n "   Running... "
            
            local output
            output=$(cd "$project_dir" && go test ./features_test/... -v 2>&1)
            local exit_code=$?
            
            # Strip ANSI codes and count
            local clean_output
            clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
            
            local scenarios=0
            local passed=0
            local failed=0
            
            # Count tests (subtract 1 for TestFeatures parent)
            passed=$(echo "$clean_output" | grep -ce "--- PASS:" || echo "0")
            failed=$(echo "$clean_output" | grep -ce "--- FAIL:" || echo "0")
            scenarios=$((passed - 1))  # Remove parent test
            [ $scenarios -lt 0 ] && scenarios=0
            
            if [ $exit_code -eq 0 ]; then
                echo "✅ $scenarios passed"
                results+=("✅|$rel_path|godog|$feature_count|$scenarios|$implemented|$todo|$wip|$bug|0")
            else
                echo "❌ $failed failed, $scenarios passed"
                results+=("❌|$rel_path|godog|$feature_count|$scenarios|$implemented|$todo|$wip|$bug|$failed")
            fi
            
        elif [ -d "$project_dir/tests" ] || find "$project_dir" -name "*_test.go" -not -path "*/vendor/*" | head -1 | grep -q .; then
            echo "   Framework: go test"
            echo -n "   Running... "
            
            local output
            output=$(cd "$project_dir" && go test ./... 2>&1)
            local exit_code=$?
            
            # Strip ANSI codes and count
            local clean_output
            clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
            
            local passed=0
            local failed=0
            passed=$(echo "$clean_output" | grep -ce "--- PASS:" || echo "0")
            failed=$(echo "$clean_output" | grep -ce "--- FAIL:" || echo "0")
            
            if [ $exit_code -eq 0 ]; then
                echo "✅ $passed passed"
                results+=("✅|$rel_path|go test|0|$passed|0|0|0|0|0")
            else
                echo "❌ $failed failed, $passed passed"
                results+=("❌|$rel_path|go test|0|$passed|0|0|0|0|$failed")
            fi
            
        else
            echo "   Framework: -"
            echo "   ⏭️  No tests found"
            results+=("⏭️|$rel_path|none|0|0|0|0|0|0|0")
        fi
        echo ""
        
    done < <(find "$root_dir" -name "go.mod" -not -path "*/vendor/*" -print0 2>/dev/null)
    
    # Find Node/Frontend projects (with package.json)
    while IFS= read -r -d '' pkg_json; do
        local project_dir
        project_dir=$(dirname "$pkg_json")
        local rel_path
        rel_path="${project_dir#$root_dir/}"
        
        # Skip node_modules, packages, and build output
        [[ "$project_dir" == *"node_modules"* ]] && continue
        [[ "$project_dir" == *"/packages/"* ]] && continue
        [[ "$project_dir" == *".output"* ]] && continue
        
        ((project_count++))
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📦 $rel_path"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Find feature files and count tags
        local feature_count=0
        local implemented=0
        local todo=0
        local wip=0
        local bug=0
        
        if [ -d "$project_dir/tests" ]; then
            feature_count=$(find "$project_dir/tests" -name "*.feature" 2>/dev/null | wc -l | tr -d ' ')
            
            # Count tags (feature-level and scenario-level)
            local all_content
            all_content=$(cat "$project_dir/tests"/**/*.feature 2>/dev/null || echo "")
            implemented=$(echo "$all_content" | grep -o "@implemented" | wc -l || echo "0")
            todo=$(echo "$all_content" | grep -o "@todo" | wc -l || echo "0")
            wip=$(echo "$all_content" | grep -o "@wip" | wc -l || echo "0")
            bug=$(echo "$all_content" | grep -o "@bug" | wc -l || echo "0")
        fi
        
        # Check for cucumber/gherkin tests
        if [ -d "$project_dir/tests" ] && [ "$feature_count" -gt 0 ]; then
            if grep -q "cucumber\|@cucumber" "$pkg_json" 2>/dev/null; then
                echo "   Framework: Cucumber"
                echo "   Features:  $feature_count files | ✅$implemented implemented | 📋$todo todo | 🔧$wip wip | 🐛$bug bug"
                echo -n "   Running... "
                
                local output
                output=$(cd "$project_dir" && pnpm test 2>&1)
                local exit_code=$?
                
                # Parse cucumber output
                local scenarios=0
                local passed=0
                local failed=0
                
                scenarios=$(echo "$output" | grep -oP '\d+ scenarios?' | grep -oP '\d+' | head -1 || echo "0")
                passed=$(echo "$output" | grep -oP '\d+ passed' | grep -oP '\d+' | head -1 || echo "0")
                failed=$(echo "$output" | grep -oP '\d+ failed' | grep -oP '\d+' | head -1 || echo "0")
                
                if [ $exit_code -eq 0 ]; then
                    echo "✅ $scenarios passed"
                    results+=("✅|$rel_path|Cucumber|$feature_count|$scenarios|$implemented|$todo|$wip|$bug|0")
                else
                    echo "❌ $failed failed, $passed passed"
                    results+=("❌|$rel_path|Cucumber|$feature_count|$passed|$implemented|$todo|$wip|$bug|$failed")
                fi
            else
                echo "   Framework: Cucumber ($feature_count files)"
                echo "   ⏭️  Cucumber not installed"
                results+=("⏭️|$rel_path|Cucumber|$feature_count|0|$implemented|$todo|$wip|$bug|0")
            fi
        else
            echo "   Framework: -"
            echo "   ⏭️  No tests found"
            results+=("⏭️|$rel_path|none|0|0|0|0|0|0|0")
        fi
        echo ""
        
    done < <(find "$root_dir" -name "package.json" -not -path "*/node_modules/*" -print0 2>/dev/null)
    
    # Summary Table
    echo "═══════════════════════════════════════════════════════════════════════════════════"
    echo "📊 Test Results"
    echo "═══════════════════════════════════════════════════════════════════════════════════"
    printf "%-40s %-10s %5s %8s %7s %7s %7s %7s\n" "Project" "Framework" "Files" "Passed" "✅impl" "📋todo" "🔧wip" "🐛bug"
    echo "───────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    local total_passed=0
    local total_failed=0
    local total_files=0
    local total_impl=0
    local total_todo=0
    local total_wip=0
    local total_bug=0
    
    for result in "${results[@]}"; do
        IFS='|' read -r status path framework files passed impl todo wip bug failed <<< "$result"
        
        printf "%-40s %-10s %5s %8s %7s %7s %7s %7s\n" "$path" "$framework" "$files" "$passed" "$impl" "$todo" "$wip" "$bug"
        
        total_files=$((total_files + files))
        total_passed=$((total_passed + passed))
        total_failed=$((total_failed + failed))
        total_impl=$((total_impl + impl))
        total_todo=$((total_todo + todo))
        total_wip=$((total_wip + wip))
        total_bug=$((total_bug + bug))
    done
    
    echo "───────────────────────────────────────────────────────────────────────────────────────────────────────"
    printf "%-40s %-10s %5s %8s %7s %7s %7s %7s\n" "TOTAL ($project_count projects)" "" "$total_files" "$total_passed" "$total_impl" "$total_todo" "$total_wip" "$total_bug"
    echo ""
    
    if [ $total_failed -eq 0 ]; then
        echo "🎉 All tests passed!"
        return 0
    else
        echo "💥 $total_failed tests failed!"
        return 1
    fi
}

# Quick test - just show what would be tested
main_test_discover() {
    local root_dir="${1:-.}"
    
    # Resolve to absolute path
    if [[ "$root_dir" != /* ]]; then
        root_dir="$(pwd)/$root_dir"
    fi
    
    echo "🔍 Projects with tests in: $root_dir"
    echo ""
    
    echo "🔷 Go Projects:"
    find "$root_dir" -name "go.mod" -not -path "*/vendor/*" -not -path "*/node_modules/*" 2>/dev/null | while read -r go_mod; do
        local dir
        dir=$(dirname "$go_mod")
        local rel_path
        rel_path="${dir#$root_dir/}"
        
        if [ -d "$dir/features_test" ]; then
            # Count feature files
            local count=0
            [ -d "$dir/features" ] && count=$(find "$dir/features" -name "*.feature" 2>/dev/null | wc -l | tr -d ' ')
            [ -d "$root_dir/features" ] && count=$(find "$root_dir/features" -name "*.feature" 2>/dev/null | wc -l | tr -d ' ')
            echo "   ✅ $rel_path (godog, $count features)"
        elif find "$dir" -name "*_test.go" -not -path "*/vendor/*" | head -1 | grep -q .; then
            echo "   ✅ $rel_path (go test)"
        fi
    done
    
    echo ""
    echo "🔶 Node Projects:"
    find "$root_dir" -name "package.json" -not -path "*/node_modules/*" 2>/dev/null | while read -r pkg; do
        local dir
        dir=$(dirname "$pkg")
        
        [[ "$dir" == *"node_modules"* ]] && continue
        [[ "$dir" == *".output"* ]] && continue
        
        local rel_path
        rel_path="${dir#$root_dir/}"
        
        if [ -d "$dir/tests" ]; then
            local feature_count=0
            feature_count=$(find "$dir/tests" -name "*.feature" 2>/dev/null | wc -l | tr -d ' ')
            
            if [ "$feature_count" -gt 0 ]; then
                if grep -q "cucumber\|@cucumber" "$pkg" 2>/dev/null; then
                    echo "   ✅ $rel_path (Cucumber, $feature_count features)"
                else
                    echo "   ⚠️  $rel_path (Cucumber files, but not installed)"
                fi
            fi
        fi
    done
}
