#!/bin/bash
# Ralph Loop Runner
# Orchestrates iterative AI-driven development
#
# Prerequisites:
#   - RALPH.md: Task definitions (create this for your project)
#   - progress.txt: State tracking (initialize with "Next: <first-task>")
#   - config.yaml: Configuration (copy template and customize)

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
LOG_DIR="$SCRIPT_DIR/logs"

# These will be set from config.yaml (with defaults)
RALPH_FILE=""
PROGRESS_FILE=""
CONTEXT_FILES=()
REPO1_VERIFY=""
REPO2_VERIFY=""
RETRY_ON_ERROR=0
HOOK_POST_TASK=""
HOOK_POST_GROUP=""
HOOK_ON_COMPLETE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Simple YAML parser - extracts value for a key
# Usage: yaml_get "key.subkey" file.yaml
# Supports up to 3 levels: "repos.backend.path"
yaml_get() {
    local key="$1"
    local file="$2"
    local value=""

    # Count dots to determine nesting level
    local dots="${key//[^.]}"
    local level=${#dots}

    if [ $level -eq 2 ]; then
        # Three-level nesting: repos.backend.path
        local l1="${key%%.*}"
        local rest="${key#*.}"
        local l2="${rest%%.*}"
        local l3="${rest#*.}"
        value=$(awk -v l1="$l1" -v l2="$l2" -v l3="$l3" '
            $0 ~ "^"l1":" { in_l1=1; next }
            in_l1 && /^[a-zA-Z]/ && $0 !~ "^  " { in_l1=0 }
            in_l1 && $0 ~ "^  "l2":" { in_l2=1; next }
            in_l2 && /^  [a-zA-Z]/ && $0 !~ "^    " { in_l2=0 }
            in_l2 && $0 ~ "^    "l3":" {
                gsub(/^    [a-zA-Z_]+: */, "");
                gsub(/^["'"'"']|["'"'"']$/, "");
                print;
                exit
            }
        ' "$file")
    elif [ $level -eq 1 ]; then
        # Two-level nesting: permissions.mode
        local parent="${key%%.*}"
        local child="${key#*.}"
        value=$(awk -v parent="$parent" -v child="$child" '
            $0 ~ "^"parent":" { in_section=1; next }
            in_section && /^[a-zA-Z]/ && $0 !~ "^  " { in_section=0 }
            in_section && $0 ~ "^  "child":" {
                gsub(/^  [a-zA-Z_]+: */, "");
                gsub(/^["'"'"']|["'"'"']$/, "");
                print;
                exit
            }
        ' "$file")
    else
        # Top-level key
        value=$(grep "^$key:" "$file" | head -1 | sed 's/^[^:]*: *//' | sed 's/^["'\'']\|["'\'']$//g')
    fi

    echo "$value"
}

# Parse YAML array - extracts list items under a key
# Usage: yaml_get_array "permissions.allowed_tools" file.yaml
yaml_get_array() {
    local key="$1"
    local file="$2"
    local parent="${key%%.*}"
    local child="${key#*.}"

    awk -v parent="$parent" -v child="$child" '
        $0 ~ "^"parent":" { in_parent=1; next }
        in_parent && /^[a-zA-Z]/ && $0 !~ "^  " { in_parent=0 }
        in_parent && $0 ~ "^  "child":" { in_array=1; next }
        in_array && /^    - / {
            gsub(/^    - ["'\''"]?/, "");
            gsub(/["'\''"]$/, "");
            print
        }
        in_array && /^  [a-zA-Z]/ && $0 !~ "^    " { in_array=0 }
    ' "$file"
}

# Parse top-level YAML array
# Usage: yaml_get_top_array "context" file.yaml
yaml_get_top_array() {
    local key="$1"
    local file="$2"

    awk -v key="$key" '
        $0 ~ "^"key":" { in_array=1; next }
        in_array && /^[a-zA-Z]/ { in_array=0 }
        in_array && /^  - / {
            gsub(/^  - ["'\''"]?/, "");
            gsub(/["'\''"]$/, "");
            print
        }
    ' "$file"
}

# Run a hook script if configured
run_hook() {
    local hook_name="$1"
    local hook_script="$2"

    if [ -n "$hook_script" ]; then
        echo -e "${BLUE}Running $hook_name hook: $hook_script${NC}"
        if [ -f "$SCRIPT_DIR/$hook_script" ]; then
            cd "$SCRIPT_DIR"
            if bash "$hook_script"; then
                echo -e "${GREEN}$hook_name hook completed${NC}"
            else
                echo -e "${RED}$hook_name hook failed${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}Hook script not found: $hook_script${NC}"
        fi
    fi
    return 0
}

# Run verification command for a repo
run_verify() {
    local repo_dir="$1"
    local verify_cmd="$2"
    local repo_name="$3"

    if [ -z "$verify_cmd" ]; then
        return 0
    fi

    echo -e "${BLUE}Running verification for $repo_name: $verify_cmd${NC}"
    cd "$repo_dir"
    if eval "$verify_cmd"; then
        echo -e "${GREEN}Verification passed${NC}"
        return 0
    else
        echo -e "${RED}Verification failed${NC}"
        return 1
    fi
}

# Load configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file not found: $CONFIG_FILE${NC}"
        echo "Copy config.yaml.template to config.yaml and customize it."
        exit 1
    fi

    # Load ralph_file and progress_file from config (with defaults)
    local ralph_file_config=$(yaml_get "ralph_file" "$CONFIG_FILE" | sed 's/^ *//')
    local progress_file_config=$(yaml_get "progress_file" "$CONFIG_FILE" | sed 's/^ *//')

    ralph_file_config=${ralph_file_config:-RALPH.md}
    progress_file_config=${progress_file_config:-progress.txt}

    # Resolve relative to script directory
    RALPH_FILE="$SCRIPT_DIR/$ralph_file_config"
    PROGRESS_FILE="$SCRIPT_DIR/$progress_file_config"

    if [ ! -f "$RALPH_FILE" ]; then
        echo -e "${RED}Task file not found: $RALPH_FILE${NC}"
        echo "Create $ralph_file_config with your task definitions."
        exit 1
    fi

    if [ ! -f "$PROGRESS_FILE" ]; then
        echo -e "${RED}Progress file not found: $PROGRESS_FILE${NC}"
        echo "Create $progress_file_config with: Next: <first-task-id>"
        exit 1
    fi

    # Load context files
    CONTEXT_FILES=()
    while IFS= read -r ctx_file; do
        if [ -n "$ctx_file" ]; then
            # Resolve relative to script directory
            local resolved="$SCRIPT_DIR/$ctx_file"
            if [ -f "$resolved" ]; then
                CONTEXT_FILES+=("$resolved")
            else
                echo -e "${YELLOW}Context file not found: $ctx_file${NC}"
            fi
        fi
    done < <(yaml_get_top_array "context" "$CONFIG_FILE")

    # Load repo paths and task prefixes
    # Support both generic names (backend/frontend) and specific names (web-client/web-api)
    REPO1_DIR=$(yaml_get "repos.backend.path" "$CONFIG_FILE" | sed 's/^ *//')
    REPO2_DIR=$(yaml_get "repos.frontend.path" "$CONFIG_FILE" | sed 's/^ *//')
    REPO1_PREFIX=$(yaml_get "repos.backend.task_prefixes" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    REPO2_PREFIX=$(yaml_get "repos.frontend.task_prefixes" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    REPO1_VERIFY=$(yaml_get "repos.backend.verify" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    REPO2_VERIFY=$(yaml_get "repos.frontend.verify" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')

    # Fallback to web-client/web-api naming if backend/frontend not found
    if [ -z "$REPO1_DIR" ]; then
        REPO1_DIR=$(yaml_get "repos.web-api.path" "$CONFIG_FILE" | sed 's/^ *//')
        REPO1_PREFIX=$(yaml_get "repos.web-api.task_prefixes" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
        REPO1_VERIFY=$(yaml_get "repos.web-api.verify" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    fi
    if [ -z "$REPO2_DIR" ]; then
        REPO2_DIR=$(yaml_get "repos.web-client.path" "$CONFIG_FILE" | sed 's/^ *//')
        REPO2_PREFIX=$(yaml_get "repos.web-client.task_prefixes" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
        REPO2_VERIFY=$(yaml_get "repos.web-client.verify" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    fi

    # Load git settings
    FEATURE_BRANCH=$(yaml_get "git.feature_branch" "$CONFIG_FILE" | sed 's/^ *//')
    SYNC_WITH_MAIN=$(yaml_get "git.sync_with_main" "$CONFIG_FILE" | sed 's/^ *//')
    AUTO_COMMIT=$(yaml_get "git.auto_commit" "$CONFIG_FILE" | sed 's/^ *//')
    COMMIT_PREFIX=$(yaml_get "git.commit_message_prefix" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')

    # Load loop settings
    MAX_ITERATIONS=$(yaml_get "loop.max_iterations" "$CONFIG_FILE" | sed 's/^ *//')
    PAUSE_BETWEEN_ITERATIONS=$(yaml_get "loop.pause_between_seconds" "$CONFIG_FILE" | sed 's/^ *//')
    RETRY_ON_ERROR=$(yaml_get "loop.retry_on_error" "$CONFIG_FILE" | sed 's/^ *//')

    # Load hooks
    HOOK_POST_TASK=$(yaml_get "hooks.post_task" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    HOOK_POST_GROUP=$(yaml_get "hooks.post_group" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')
    HOOK_ON_COMPLETE=$(yaml_get "hooks.on_complete" "$CONFIG_FILE" | sed 's/^ *//' | tr -d '"')

    # Load permission settings
    DANGEROUS_SKIP_ALL=$(yaml_get "permissions.dangerous_skip_all" "$CONFIG_FILE" | sed 's/^ *//')
    PERMISSION_MODE=$(yaml_get "permissions.mode" "$CONFIG_FILE" | sed 's/^ *//')

    # Load allowed tools into array
    ALLOWED_TOOLS=()
    while IFS= read -r tool; do
        [ -n "$tool" ] && ALLOWED_TOOLS+=("$tool")
    done < <(yaml_get_array "permissions.allowed_tools" "$CONFIG_FILE")

    # Set defaults if empty
    MAX_ITERATIONS=${MAX_ITERATIONS:-100}
    PAUSE_BETWEEN_ITERATIONS=${PAUSE_BETWEEN_ITERATIONS:-2}
    PERMISSION_MODE=${PERMISSION_MODE:-acceptEdits}
    DANGEROUS_SKIP_ALL=${DANGEROUS_SKIP_ALL:-false}
    REPO1_PREFIX=${REPO1_PREFIX:-B}
    REPO2_PREFIX=${REPO2_PREFIX:-F}
    AUTO_COMMIT=${AUTO_COMMIT:-false}
    COMMIT_PREFIX=${COMMIT_PREFIX:-"ralph:"}
    RETRY_ON_ERROR=${RETRY_ON_ERROR:-0}
}

# Build Claude command arguments
# Returns arguments in CLAUDE_CMD_ARGS array (must be called, not captured)
build_claude_args() {
    CLAUDE_CMD_ARGS=()

    if [ "$DANGEROUS_SKIP_ALL" = "true" ]; then
        CLAUDE_CMD_ARGS+=("--dangerously-skip-permissions")
    else
        CLAUDE_CMD_ARGS+=("--permission-mode" "$PERMISSION_MODE")

        # Add allowed tools
        if [ ${#ALLOWED_TOOLS[@]} -gt 0 ]; then
            CLAUDE_CMD_ARGS+=("--allowedTools")
            for tool in "${ALLOWED_TOOLS[@]}"; do
                CLAUDE_CMD_ARGS+=("$tool")
            done
        fi
    fi

    # Add directories
    CLAUDE_CMD_ARGS+=("--add-dir" "$SCRIPT_DIR")
    [ -n "$REPO1_DIR" ] && CLAUDE_CMD_ARGS+=("--add-dir" "$REPO1_DIR")
    [ -n "$REPO2_DIR" ] && CLAUDE_CMD_ARGS+=("--add-dir" "$REPO2_DIR")

    # Separator and files
    CLAUDE_CMD_ARGS+=("--")

    # Add context files first
    for ctx_file in "${CONTEXT_FILES[@]}"; do
        CLAUDE_CMD_ARGS+=("$ctx_file")
    done

    # Add Ralph file
    CLAUDE_CMD_ARGS+=("$RALPH_FILE")
}

# Function to sync branch with main
sync_branch() {
    local repo_dir="$1"
    local repo_name="$2"

    if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ]; then
        echo -e "${YELLOW}Skipping sync for $repo_name (not configured or doesn't exist)${NC}"
        return 0
    fi

    echo -e "${BLUE}Syncing $repo_name with main...${NC}"
    cd "$repo_dir"

    # Get current branch
    current_branch=$(git branch --show-current)

    if [ "$current_branch" != "$FEATURE_BRANCH" ]; then
        echo -e "${YELLOW}Not on $FEATURE_BRANCH, switching...${NC}"
        git checkout "$FEATURE_BRANCH" 2>/dev/null || git checkout -b "$FEATURE_BRANCH"
    fi

    # Fetch and merge main
    git fetch origin main
    git merge origin/main --no-edit || {
        echo -e "${RED}Merge conflict in $repo_name. Please resolve manually.${NC}"
        return 1
    }

    echo -e "${GREEN}$repo_name synced with main${NC}"
}

# Extract task group from task ID (e.g., F0.1 -> F0, B3 -> B3)
get_task_group() {
    local task_id="$1"
    # If task has a dot (subtask), get the part before the dot
    if [[ "$task_id" == *.* ]]; then
        echo "${task_id%%.*}"
    else
        echo "$task_id"
    fi
}

# Function to auto-commit changes for a task group
auto_commit_task_group() {
    local repo_dir="$1"
    local task_group="$2"

    if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ]; then
        return 0
    fi

    cd "$repo_dir"

    # Check if there are any changes to commit
    if git diff --quiet && git diff --cached --quiet; then
        echo -e "${YELLOW}No changes to commit in $repo_dir${NC}"
        return 0
    fi

    # Get all DONE entries for this task group to build description
    local task_desc=$(grep "DONE: ${task_group}" "$PROGRESS_FILE" | head -1 | sed 's/.*DONE: [^ ]* - //' | head -c 60)

    # Stage all changes
    git add -A

    # Create commit message
    local commit_msg="$COMMIT_PREFIX $task_group - $task_desc"

    echo -e "${BLUE}Committing task group: $commit_msg${NC}"
    git commit -m "$commit_msg" || {
        echo -e "${RED}Commit failed in $repo_dir${NC}"
        return 1
    }

    echo -e "${GREEN}Committed changes for task group $task_group${NC}"
}

# Get the last completed task from progress.txt
get_last_completed_task() {
    grep "DONE:" "$PROGRESS_FILE" | tail -1 | sed 's/.*DONE: \([^ ]*\).*/\1/'
}

# Get the next task from progress.txt
get_next_task() {
    grep "Next:" "$PROGRESS_FILE" | tail -1 | sed 's/.*Next: \([^ ]*\).*/\1/'
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Load configuration
echo -e "${BLUE}=== Loading Configuration ===${NC}"
load_config

echo "Repo 1: $REPO1_DIR (prefix: $REPO1_PREFIX)"
[ -n "$REPO1_VERIFY" ] && echo "  Verify: $REPO1_VERIFY"
echo "Repo 2: $REPO2_DIR (prefix: $REPO2_PREFIX)"
[ -n "$REPO2_VERIFY" ] && echo "  Verify: $REPO2_VERIFY"
echo "Feature Branch: $FEATURE_BRANCH"
echo "Auto Commit: $AUTO_COMMIT"
echo "Max Iterations: $MAX_ITERATIONS"
echo "Retry on Error: $RETRY_ON_ERROR"
echo "Permission Mode: $([ "$DANGEROUS_SKIP_ALL" = "true" ] && echo "dangerously-skip-permissions" || echo "$PERMISSION_MODE")"
if [ "$DANGEROUS_SKIP_ALL" != "true" ] && [ ${#ALLOWED_TOOLS[@]} -gt 0 ]; then
    echo "Allowed Tools: ${ALLOWED_TOOLS[*]}"
fi
if [ ${#CONTEXT_FILES[@]} -gt 0 ]; then
    echo "Context Files: ${CONTEXT_FILES[*]}"
fi
[ -n "$HOOK_POST_TASK" ] && echo "Hook post_task: $HOOK_POST_TASK"
[ -n "$HOOK_POST_GROUP" ] && echo "Hook post_group: $HOOK_POST_GROUP"
[ -n "$HOOK_ON_COMPLETE" ] && echo "Hook on_complete: $HOOK_ON_COMPLETE"
echo ""

# Initial sync before starting loop
if [ "$SYNC_WITH_MAIN" = "true" ]; then
    echo -e "${BLUE}=== Initial Repository Sync ===${NC}"
    sync_branch "$REPO1_DIR" "repo1"
    sync_branch "$REPO2_DIR" "repo2"
    echo ""
fi

# Track timing
START_TIME=$(date +%s)
ITERATION=0
RETRY_COUNT=0

echo -e "${BLUE}=== Ralph Loop Started ===${NC}"
echo -e "Ralph file: $RALPH_FILE"
echo -e "Progress file: $PROGRESS_FILE"
echo ""

while :; do
    ITERATION=$((ITERATION + 1))
    ITERATION_START=$(date +%s)
    LOG_FILE="$LOG_DIR/iteration-$ITERATION-$(date +%Y%m%d-%H%M%S).log"

    echo -e "${YELLOW}=== Iteration $ITERATION started at $(date) ===${NC}"

    # Get the next task and determine which repo to use based on prefix
    NEXT_TASK=$(get_next_task)
    echo -e "Next task: ${BLUE}$NEXT_TASK${NC}"

    # Determine which directory to work in based on task prefix
    if [[ "$NEXT_TASK" == ${REPO1_PREFIX}* ]]; then
        WORK_DIR="$REPO1_DIR"
        CURRENT_VERIFY="$REPO1_VERIFY"
        echo -e "Working directory: ${BLUE}$WORK_DIR${NC} (repo1)"
    else
        WORK_DIR="$REPO2_DIR"
        CURRENT_VERIFY="$REPO2_VERIFY"
        echo -e "Working directory: ${BLUE}$WORK_DIR${NC} (repo2)"
    fi

    # Build and run Claude command
    cd "$WORK_DIR"
    build_claude_args  # Sets CLAUDE_CMD_ARGS array

    echo -e "Running: claude ${CLAUDE_CMD_ARGS[*]}"

    if claude "${CLAUDE_CMD_ARGS[@]}" 2>&1 | tee "$LOG_FILE"; then
        EXIT_CODE=0
        RETRY_COUNT=0  # Reset retry count on success
    else
        EXIT_CODE=$?
    fi

    ITERATION_END=$(date +%s)
    ITERATION_DURATION=$((ITERATION_END - ITERATION_START))

    echo -e "Iteration $ITERATION completed in ${GREEN}${ITERATION_DURATION}s${NC}"

    # Check for errors
    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}ERROR: Claude exited with code $EXIT_CODE${NC}"

        # Retry logic
        if [ $RETRY_COUNT -lt $RETRY_ON_ERROR ]; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo -e "${YELLOW}Retrying... (attempt $RETRY_COUNT of $RETRY_ON_ERROR)${NC}"
            sleep 2
            continue
        fi

        echo "Check log: $LOG_FILE"
        break
    fi

    # Check for error marker in progress file
    if grep -q "^ERROR:" "$PROGRESS_FILE" 2>/dev/null; then
        echo -e "${RED}ERROR marker found in progress.txt${NC}"
        grep "^ERROR:" "$PROGRESS_FILE"

        # Retry logic for progress file errors
        if [ $RETRY_COUNT -lt $RETRY_ON_ERROR ]; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo -e "${YELLOW}Retrying... (attempt $RETRY_COUNT of $RETRY_ON_ERROR)${NC}"
            # Remove the error marker before retry
            sed -i '' '/^ERROR:/d' "$PROGRESS_FILE" 2>/dev/null || sed -i '/^ERROR:/d' "$PROGRESS_FILE"
            sleep 2
            continue
        fi

        break
    fi

    # Run verification if configured
    if [ -n "$CURRENT_VERIFY" ]; then
        if ! run_verify "$WORK_DIR" "$CURRENT_VERIFY" "current repo"; then
            echo -e "${RED}Verification failed after task completion${NC}"

            # Retry logic for verification failures
            if [ $RETRY_COUNT -lt $RETRY_ON_ERROR ]; then
                RETRY_COUNT=$((RETRY_COUNT + 1))
                echo -e "${YELLOW}Retrying... (attempt $RETRY_COUNT of $RETRY_ON_ERROR)${NC}"
                sleep 2
                continue
            fi

            break
        fi
    fi

    # Run post-task hook
    run_hook "post_task" "$HOOK_POST_TASK"

    # Auto-commit if enabled and task group changed
    if [ "$AUTO_COMMIT" = "true" ]; then
        COMPLETED_TASK=$(get_last_completed_task)
        NEW_NEXT_TASK=$(get_next_task)

        if [ -n "$COMPLETED_TASK" ] && [ -n "$NEW_NEXT_TASK" ]; then
            COMPLETED_GROUP=$(get_task_group "$COMPLETED_TASK")
            NEXT_GROUP=$(get_task_group "$NEW_NEXT_TASK")

            # Commit when task group changes (e.g., F0.5 -> F1.1, or B1 -> B2)
            if [ "$COMPLETED_GROUP" != "$NEXT_GROUP" ]; then
                echo -e "${BLUE}Task group changed: $COMPLETED_GROUP -> $NEXT_GROUP${NC}"

                # Determine which repo the completed task group belongs to
                if [[ "$COMPLETED_TASK" == ${REPO1_PREFIX}* ]]; then
                    auto_commit_task_group "$REPO1_DIR" "$COMPLETED_GROUP"
                else
                    auto_commit_task_group "$REPO2_DIR" "$COMPLETED_GROUP"
                fi

                # Run post-group hook
                run_hook "post_group" "$HOOK_POST_GROUP"
            fi
        fi
    fi

    # Check if all tasks complete
    if grep -q "RALPH_COMPLETE" "$PROGRESS_FILE" 2>/dev/null; then
        echo -e "${GREEN}All tasks completed!${NC}"

        # Final commit for the last task group
        if [ "$AUTO_COMMIT" = "true" ]; then
            COMPLETED_TASK=$(get_last_completed_task)
            if [ -n "$COMPLETED_TASK" ]; then
                COMPLETED_GROUP=$(get_task_group "$COMPLETED_TASK")
                echo -e "${BLUE}Final commit for task group: $COMPLETED_GROUP${NC}"

                if [[ "$COMPLETED_TASK" == ${REPO1_PREFIX}* ]]; then
                    auto_commit_task_group "$REPO1_DIR" "$COMPLETED_GROUP"
                else
                    auto_commit_task_group "$REPO2_DIR" "$COMPLETED_GROUP"
                fi
            fi
        fi

        # Run on_complete hook
        run_hook "on_complete" "$HOOK_ON_COMPLETE"

        break
    fi

    # Safety limit
    if [ $ITERATION -ge $MAX_ITERATIONS ]; then
        echo -e "${RED}Hit max iterations limit ($MAX_ITERATIONS)${NC}"
        break
    fi

    # Brief pause between iterations
    echo -e "Pausing ${PAUSE_BETWEEN_ITERATIONS}s before next iteration..."
    sleep $PAUSE_BETWEEN_ITERATIONS
    echo ""
done

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${BLUE}=== Ralph Loop Summary ===${NC}"
echo -e "Total iterations: ${GREEN}$ITERATION${NC}"
echo -e "Total time: ${GREEN}${TOTAL_DURATION}s${NC} ($(($TOTAL_DURATION / 60))m $(($TOTAL_DURATION % 60))s)"
echo -e "Logs directory: $LOG_DIR"
