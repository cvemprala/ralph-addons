# Todo App

A simple Todo application with Go backend and React frontend.

---

## Instructions

Read `progress.txt` to determine the current task. Complete ONE task, update progress.txt, then STOP.

### After completing a task:
1. Run the verification command for the repo (`go build ./...` or `pnpm tsc --noEmit`)
2. Update progress.txt with: `[timestamp] DONE: <task-id> - <brief description>`
3. Add `Next: <next-task-id>` line
4. STOP

### If all tasks are done:
Write `RALPH_COMPLETE` to progress.txt

### If something fails:
Write `ERROR: <description>` to progress.txt and STOP

---

## B1: Todo Model

**File**: `models/todo.go`

Create Todo struct with fields:
- ID (uuid)
- Title (string)
- Completed (bool)
- CreatedAt (time.Time)

Include JSON tags for API serialization.

---

## B2: Todo Repository

**File**: `repository/todo.go`

Create in-memory repository with methods:
- Create(todo) error
- GetAll() []Todo
- GetByID(id) (Todo, error)
- Update(todo) error
- Delete(id) error

---

## B3: Todo Handlers

**File**: `handlers/todo.go`

Create HTTP handlers:
- POST /todos - create todo
- GET /todos - list all todos
- GET /todos/:id - get single todo
- PUT /todos/:id - update todo
- DELETE /todos/:id - delete todo

Wire up routes in main.go.

---

## B4: Backend Tests

Run `go test ./...` and ensure all tests pass.

If no tests exist, create basic tests for the repository.

---

## F1.1: Todo Types

**File**: `src/types/todo.ts`

```typescript
export interface Todo {
  id: string;
  title: string;
  completed: boolean;
  createdAt: string;
}
```

---

## F1.2: API Client

**File**: `src/api/todos.ts`

Create API client functions:
- getTodos(): Promise<Todo[]>
- createTodo(title: string): Promise<Todo>
- updateTodo(id: string, updates: Partial<Todo>): Promise<Todo>
- deleteTodo(id: string): Promise<void>

Use fetch. Base URL from environment variable.

---

## F2.1: TodoList Component

**File**: `src/components/TodoList.tsx`

Display list of todos with:
- Checkbox to toggle completed
- Delete button
- Empty state when no todos

---

## F2.2: TodoForm Component

**File**: `src/components/TodoForm.tsx`

Form to add new todos:
- Text input for title
- Submit button
- Clear input after submit

---

## F3: App Integration

**File**: `src/App.tsx`

Wire up components:
- Fetch todos on mount
- Pass handlers to components
- Handle loading and error states
