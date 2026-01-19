# Ralph Loop

AI-assisted iterative development. A simple bash loop that repeatedly feeds the same prompt to an AI agent.

---

## The Core Idea

```bash
while :; do claude "@TASKS.md"; done
```

That's it. Loop an AI agent with the same prompt until the work is done.

You wouldn't give a junior dev "build an org management page" and walk away. You'd write tickets with clear scope, acceptance criteria, and references. Do the same for AI.

```markdown
# TASKS.md
1. Create user model
2. Create auth endpoints
3. Create login form
4. Wire it up
```

Each iteration:
1. AI reads the task list
2. Does one task
3. Updates state
4. Stops

Loop restarts. Next task. Repeat.

---

## Why It Works

Using Jira as an example to illustrate the mapping (not pushing Jira - use whatever project management tool you prefer or do not use one at all):

```
Traditional Dev     ->  Ralph Loop
---------------------------------------------
Jira epic           ->  RALPH.md (feature description)
Jira stories        ->  Task groups (B1-B6, F0-F8)
Jira subtasks       ->  Individual subtasks (F0.1, F0.2)
Sprint board        ->  progress.txt
Definition of done  ->  Verification commands (go build, pnpm tsc)
```

AI gets the same clarity a developer would get from a well-written ticket.

---

## The Problem With Simple

The one-liner works, but real projects need more.

Say you're building a user authentication feature - backend in Go, frontend in React. (The stack doesn't matter - this works with any language/framework.)

| Challenge | Question |
|-----------|----------|
| Multiple repos | Backend and frontend are separate - which one does the AI work in? |
| Permissions | AI keeps asking "can I edit this file?" - how do I auto-approve? |
| State tracking | How does the AI know what's done and what's next? |
| Git hygiene | I want commits per feature, not a mess of changes |
| Verification | How do I ensure `go build` passes before moving on? |

---

## What We Built

Same core idea, with infrastructure:

```
my-feature/
├── config.yaml       # All settings in one place
├── RALPH.md          # Task definitions
├── progress.txt      # State tracking
├── ralph-loop.sh     # Runner script
└── logs/             # Iteration history
```

### Config-Driven Setup

Everything lives in `config.yaml`:

```yaml
# Task and progress files
ralph_file: RALPH.md
progress_file: progress.txt

repos:
  backend:
    path: /code/backend
    task_prefixes: B      # B* tasks go here
  frontend:
    path: /code/frontend
    task_prefixes: F      # F* tasks go here

git:
  feature_branch: feature/user-auth
  auto_commit: true
  commit_message_prefix: "feat:"

permissions:
  mode: acceptEdits
  allowed_tools:
    - "Bash(go:*)"
    - "Bash(npm:*)"
```

### Task Routing

Tasks automatically route to the right repo:

```
B1: Create user model     -> /code/backend
B2: Create auth endpoints -> /code/backend
F1: Create login form     -> /code/frontend
F2: Add auth context      -> /code/frontend
```

### Auto-Commits Per Task Group

Commits happen when the task **group** changes, not per subtask:

```
F1.1 -> F1.2 -> F1.3 -> F2.1
                    ^
                 commit "feat: F1 - Created login form"
```

Clean history.

### Progress Tracking

`progress.txt` is the source of truth:

```
[2024-01-15 10:30] DONE: B1 - Created user model
Next: B2

[2024-01-15 10:45] DONE: B2 - Created auth endpoints
Next: F1.1
```

Signals:
- `RALPH_COMPLETE` - all done
- `ERROR: go build failed` - stops the loop

---

## Task Grammar

Flexible naming. Use whatever fits your project.

```
<PREFIX><GROUP>[.<SUBTASK>]
```

| Task ID | Prefix | Group | Subtask |
|---------|--------|-------|---------|
| `B1` | B | 1 | - |
| `F2.3` | F | 2 | 3 |
| `API-USER-1` | API-USER- | 1 | - |

Prefix determines repo:

```yaml
repos:
  backend:
    task_prefixes: B,API,DB
  frontend:
    task_prefixes: F,UI,PAGE
  mobile:
    task_prefixes: M,IOS,ANDROID
```

---

## Quick Start

### 1. Create orchestration folder (outside your repos)

```
/work/my-feature/
├── config.yaml
├── RALPH.md
├── progress.txt
└── ralph-loop.sh
```

### 2. Define tasks in `RALPH.md`

```markdown
# User Authentication

## B1: User Model
**File**: `models/user.go`
Create User struct with id, email, password_hash.

## B2: Auth Endpoints
**File**: `handlers/auth.go`
POST /login and POST /register.

## F1.1: Login Form
**File**: `src/components/LoginForm.tsx`
Email and password fields.
```

### 3. Configure `config.yaml`

```yaml
ralph_file: RALPH.md
progress_file: progress.txt

repos:
  backend:
    path: /code/backend
    task_prefixes: B
  frontend:
    path: /code/frontend
    task_prefixes: F

git:
  feature_branch: feature/auth
  auto_commit: true
  commit_message_prefix: "feat:"

permissions:
  mode: acceptEdits
  allowed_tools:
    - "Bash(go:*)"
    - "Bash(npm:*)"
```

### 4. Initialize `progress.txt`

```
# Auth Feature
Next: B1
```

### 5. Run

```bash
./ralph-loop.sh
```

---

## Example Output

```
=== Loading Configuration ===
Backend: /code/backend (prefix: B)
Frontend: /code/frontend (prefix: F)
Auto Commit: true

=== Iteration 1 ===
Next task: B1
Working directory: /code/backend
...
Iteration 1 completed in 45s

=== Iteration 6 ===
Task group changed: B3 -> F1
Committing: feat: B3 - Backend tests passing

=== Ralph Loop Summary ===
Total iterations: 10
Total time: 8m 32s
```

Git history:
```
feat: B1 - Todo struct
feat: B2 - CRUD endpoints
feat: B3 - Backend tests passing
feat: F1 - Types and API client
feat: F2 - TodoList and TodoForm
```

---

## Configuration Options

### Verification commands per repo

Run a command after each task to verify it worked:

```yaml
repos:
  backend:
    path: /code/backend
    task_prefixes: B
    verify: "go build ./..."
  frontend:
    path: /code/frontend
    task_prefixes: F
    verify: "pnpm tsc --noEmit"
```

Verification runs after each task. If it fails, the loop stops (or retries if configured).

### Context files

Files Claude should always read for consistency:

```yaml
context:
  - ./CODING_STANDARDS.md
  - ./API_PATTERNS.md
```

These get passed to Claude every iteration. Useful for enforcing patterns across tasks.

### Hooks

Run scripts at specific points:

```yaml
hooks:
  post_task: "./scripts/run-lint.sh"      # After each task
  post_group: "./scripts/run-tests.sh"    # After task group changes (F1 -> F2)
  on_complete: "./scripts/notify.sh"      # When all tasks done
```

Hook scripts run from the orchestration directory.

### Retry on failure

Sometimes Claude fails on first attempt but succeeds on retry:

```yaml
loop:
  retry_on_error: 2  # Retry up to 2 times on failure
```

Retries happen for:
- Claude exit code errors
- ERROR marker in progress.txt
- Verification failures

### More repos

```yaml
repos:
  backend:
    task_prefixes: API,DB
  frontend:
    task_prefixes: UI
  mobile:
    task_prefixes: IOS,ANDROID
```

### More allowed commands

```yaml
allowed_tools:
  - "Bash(docker:*)"
  - "Bash(kubectl:*)"
  - "Bash(make:*)"
```

### Skip git sync

```yaml
git:
  sync_with_main: false
```

### Bypass all permissions

```yaml
permissions:
  dangerous_skip_all: true
```

---

## Key Points

1. **Task decomposition is the real work** - the loop is trivial, breaking features into unambiguous subtasks is where the value is

2. **State belongs in files** - don't rely on AI remembering context, write it down

3. **Verification is part of the task** - "Create auth.go" isn't done until `go build` passes

4. **Separate orchestration from code** - keep your repos clean, no untracked files polluting git status

5. **Treat AI like any engineer** - give it clear, well-scoped work

---

## Prerequisites

Before running:
1. **RALPH.md** - your task definitions
2. **progress.txt** - initialize with `Next: <first-task-id>`

These are project-specific. Create them for each feature.

See the `examples/` directory for a complete sample project (Todo app) you can copy and modify.

---

## What We Skipped

Some features we intentionally left out:

- **Parallel execution across repos** - coordination is hard, not worth the complexity
- **AI model selection** - Claude CLI handles this already
- **Notifications (Slack, email)** - most people just watch the terminal, adds unnecessary dependencies

These aren't blockers. Keep it simple.

---

## FAQ

**Why "Ralph"?**
No meaning. Call it `TASKS.md`, `BUILD.md`, whatever.

**Works with other AI tools?**
Yes. Any AI that reads files and runs commands.

**What if AI makes a mistake?**
Next iteration reads actual state and corrects. Small tasks = small mistakes.

**Can I pause and resume?**
Yes. `progress.txt` tracks state. Stop anytime, restart later.
