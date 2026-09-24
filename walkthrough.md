# Twin, end to end: architecture and code walkthrough

This document explains how Twin works, from the browser down to the container
the coding agent runs in. It starts with the overall shape, then covers the
ideas you need to know first. After that it follows two real journeys through
the code, step by step: a chat message, and a coding task. At each step it
explains what the code does, why it is written that way, and what would go
wrong otherwise.

It is written for someone who has never seen this codebase. You don't need to
know Temporal, LangGraph, Redis Streams, ACP or Docker security beforehand:
section 2 explains each one before it is used.

**Branch.** Everything here describes the `feat/production-runtime` branches of
`twin-engine`, `twin-backend`, `twin-frontend` and the root repository, which
are the pull requests that bring this work to `dev` (and to `main` for the root
repository). Section 11 covers what happened to the plan to remove Claude
Code.

**Links.** Paths start at the `twin-wrapper` root, so the first folder names
the repository. Line anchors such as `thread.py#L160` open at that line in
VS Code.

---

## Contents

1. [The big picture](#1-the-big-picture)
2. [Ideas you need first](#2-ideas-you-need-first)
3. [Journey A: a chat message](#3-journey-a-a-chat-message)
4. [Journey A, continued: approvals, stops and queued messages](#4-journey-a-continued-approvals-stops-and-queued-messages)
5. [Journey B: a coding task](#5-journey-b-a-coding-task)
6. [Inside the box](#6-inside-the-box)
7. [Journey C: a task in a GitHub repository](#7-journey-c-a-task-in-a-github-repository)
8. [The frontend in depth](#8-the-frontend-in-depth)
9. [The twin's harness](#9-the-twins-harness)
10. [Operations: evals, metrics, limits](#10-operations-evals-metrics-limits)
11. [Claude Code (M6): the connector stays, the twin stops coding through it](#11-claude-code-m6-the-connector-stays-the-twin-stops-coding-through-it)
12. [What happens when something dies](#12-what-happens-when-something-dies)
13. [Sharp edges found while writing this](#13-sharp-edges-found-while-writing-this)
14. [Glossary](#14-glossary)

---

## 1. The big picture

### 1.1 What Twin is

Twin is a digital twin of a person: an agent that acts for them, in their
voice, on their tools (GitHub, Slack and so on). You chat with it in a web app.
When you ask for code (an app, a fix, a feature), it writes a small change
itself, and anything bigger becomes a **coding task**, which runs in the
background in a sandboxed container using an agent called **DeepSeek Harness
(dsh)**. The chat
stays free while the task works, and the task reports back to the chat when it
finishes or needs you.

### 1.2 The processes

Everything runs from the root [docker-compose.yml](docker-compose.yml). These
are the services that matter here:

| Service | Started by | What it does | Talks to |
| --- | --- | --- | --- |
| `frontend` | Next.js | The web app on :4000 | backend |
| `backend` | Fastify (`twin-backend`) | Accounts, OAuth tokens, MCP tools for GitHub/Slack, and the browser's API. Proxies chat and tasks to the engine | engine, Redis, Postgres |
| `engine` | `python -m twin_relay` | The engine's HTTP API. Stateless. Turns every command into a Temporal signal. Serves reads, skills and metrics | Temporal, Postgres, Redis |
| `engine-worker` | `python -m twin_workflows` | Runs every chat turn (the twin thinking and calling tools) | Temporal, Postgres, Redis, model provider, backend's MCP |
| `code-worker` | `python -m twin_code` | Runs every coding task. The only process that controls Docker | Temporal, Postgres, Redis, docker-proxy, backend |
| `docker-proxy` | tecnativa/docker-socket-proxy | A filter in front of the Docker socket | Docker |
| `llm-proxy` | `python -m twin_code.llm_proxy` | Boxes' only route to a model. Holds the model key, charges each task | OpenRouter, Postgres |
| `git-proxy` | `python -m twin_code.git_proxy` | Boxes' only route to GitHub with a credential. Allows one branch | GitHub, backend, Postgres |
| `egress` | Squid | Boxes' only route to the internet (package registries, GitHub reads) | the internet |
| `preview` | Caddy | Serves a box's running app at `http://<box>.<port>.preview.localhost:47620` | boxes |
| `temporal` | Temporal dev server (`temporal server start-dev`) | Stores workflow history, hands out work. UI on 127.0.0.1:8233 | a SQLite file on the `twin-temporal-data` volume |
| `postgres`, `redis` | — | The database, and the live streams | — |
| boxes | created by `code-worker` | One container per project, named `twinbox-<hex>`, running dsh | the proxies only |

The service definitions are at
[docker-compose.yml:248](docker-compose.yml#L248) (temporal),
[:273](docker-compose.yml#L273) (engine),
[:369](docker-compose.yml#L369) (engine-worker),
[:421](docker-compose.yml#L421) (code-worker),
[:459](docker-compose.yml#L459) (docker-proxy),
[:481](docker-compose.yml#L481) (llm-proxy),
[:496](docker-compose.yml#L496) (git-proxy),
[:512](docker-compose.yml#L512) (egress) and
[:522](docker-compose.yml#L522) (preview).

### 1.3 The three networks

```
 default network (10.201/16) ─ everything that isn't a box
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ frontend  backend  engine  engine-worker  code-worker  postgres  redis   │
 │ temporal  llm-proxy  git-proxy  egress  preview                          │
 └──────────────────────────────────────────────────────────────────────────┘
        │                                   │
        │ docker-api (internal)             │ twin-sandbox (internal, 10.202/16)
        │ code-worker ⇄ docker-proxy only   │ boxes ⇄ llm-proxy, git-proxy, egress, preview
        ▼                                   ▼
   Docker socket                     twinbox-<hex> containers
```

- **`twin-sandbox`** ([docker-compose.yml:784](docker-compose.yml#L784)) is
  marked `internal: true`. Docker gives an internal network **no gateway**: a
  container on it can reach other containers on it by name, and nothing else.
  No internet, no host, no Postgres. The four control-plane services
  (`llm-proxy`, `git-proxy`, `egress`, `preview`) sit on **both** this network
  and `default`, so they are the only bridges out.
- **`docker-api`** ([docker-compose.yml:791](docker-compose.yml#L791)) is
  internal too, and holds only `code-worker` and `docker-proxy`. So nothing
  else can even reach the Docker API.
- **`default`** is everything else.

### 1.4 Where state lives

| Store | What is in it | Who writes it |
| --- | --- | --- |
| Postgres, `runs` | One row per turn: status, cost, output | `agent_runtime` (inside `run_turn`) |
| Postgres, LangGraph checkpoints | The twin's conversation state after every graph step | LangGraph (inside `run_turn`) |
| Postgres, `chat_threads` / `chat_turns` / `chat_decisions` | The chat as the page draws it (the "projection") | the projector (`Drainer`) |
| Postgres, `projects` / `tasks` / `task_events` | Coding tasks and what they did | `code-worker`, `engine` |
| Postgres, `skills` | Company and personal playbooks | `engine` |
| Temporal's own database (SQLite locally; Temporal Cloud in production) | Every workflow's history (encrypted) | Temporal |
| Redis Stream `twin:frames:{<thread>}` | A chat's live frames (tokens, tool calls), for about two days | `engine-worker` |
| Redis Stream `twin:task:{<task>}` | A task's live events, for about seven days | `code-worker` |
| Box volumes `twinbox-<hex>-workspace` / `-home` | The project's code; dsh's sessions, profile, skills and acpd's log | the box |

A rule runs through all of this: **Postgres is the record, Redis is a live
window onto it, and Temporal holds "what happens next".** If Redis loses
something, the page reloads from Postgres. If a worker dies, Temporal knows
what it was doing and hands it to another.

### 1.5 Two workflows, one idea

There are exactly two kinds of long-lived process in Twin, and both are
Temporal workflows:

- **`ThreadWorkflow`**, id `thread:<thread id>`: one per chat. It runs turns.
- **`CodeTaskWorkflow`**, id `task:<task id>`: one per coding task. It drives
  a box.

They talk to each other only through messages. The twin starts a task and
moves on; the task sends its chat a message when it has news. That one design
choice is why the chat never waits on a task.

---

## 2. Ideas you need first

### 2.1 Temporal, from zero

**The problem it solves.** Some work takes minutes or hours and must survive
crashes and deploys: "run this turn; if it needs approval, wait (maybe for
days); then resume". Writing that with a database and background jobs means
hand-building timeouts, retries, locks, sweepers for dead workers, and a way to
resume half-done work. Temporal is a server that does all of that for you.

**Workflow.** A function you write in ordinary Python, such as
`ThreadWorkflow.run`. Temporal records every decision it makes (start this
activity, wait for this signal, sleep until then) in an append-only
**history**. The function can "wait" for a week, and no process sits blocked
during that week.

**Replay and determinism.** When a worker picks up a workflow (say, after the
previous worker crashed), it re-runs the workflow function **from the top**,
feeding it the recorded results from the history instead of actually doing
things again. That only works if the function does exactly the same thing
every time given the same history. So workflow code must be
**deterministic**:

- no network or database calls;
- no `datetime.now()` (use `workflow.now()`);
- no `uuid4()` (use `workflow.uuid4()`);
- no random numbers.

Anything that touches the outside world goes into an **activity**. Temporal
runs workflow code in a sandbox that catches many mistakes of this kind.

**Activity.** A normal async function that may do I/O: call a model, query
Postgres, talk to Docker. Temporal gives it:

- a **start-to-close timeout** (the most time one attempt may take);
- a **retry policy** (how often to retry a failure, with backoff);
- a **heartbeat timeout**. A long activity calls `activity.heartbeat(details)`
  every few seconds. If Temporal hears nothing for the heartbeat timeout, it
  treats the worker as dead and gives the activity to another worker. The
  `details` passed to the last heartbeat are handed to the retry, so it can
  continue from there.

**Task queue.** Workers poll a named queue for work. Thread workflows and turn
activities use `twin-turns`
([wire.py:19](twin-engine/src/twin_workflows/wire.py#L19)); task workflows and
their activities use `twin-code`. So a turn never lands on the code worker, and
a Docker call never lands on the turn worker.

**Workflow id.** Every workflow has an id you choose. Temporal allows **at most
one running workflow per id**. Naming a chat's workflow `thread:<id>` therefore
guarantees, across any number of machines, that one chat has one executor.

**Signal.** A one-way message into a running workflow ("here is a new
message", "stop"). The workflow's signal handler runs and updates its state;
the main function sees the change the next time it checks a condition. A
signal can't return an answer. **Start-with-signal** starts the workflow if it
isn't running, and delivers the signal either way, in one atomic call.

**Query.** A read-only question to a running workflow ("what state are you
in?").

**`workflow.wait_condition(fn, timeout=...)`** suspends the workflow until
`fn()` becomes true (re-checked after every signal) or the timeout passes. This
is how "wait for the next message" and "wait up to six hours" are written. It
costs nothing while it waits.

**Cancellation.** Cancelling an activity sends it a cancel on its next
heartbeat. With `WAIT_CANCELLATION_COMPLETED`, the workflow waits until the
activity has actually finished cleaning up before carrying on.

**Continue-as-new.** A history can't grow forever. `continue_as_new` ends the
current run and starts a fresh one with the same id and new arguments, which
carry the state across.

**Patching.** When you change workflow code, workflows already running must
still replay their old history correctly. `workflow.patched("name")` returns
false during a replay of history recorded before the change and true
afterwards, so the old and new behaviour can coexist.

**Payload codec.** Every argument and result is serialised into a "payload"
stored in the history. A codec can transform payloads on the way in and out.
Twin's encrypts them.

### 2.2 The twin's turn: LangGraph, checkpoints, interrupts, run statuses

The twin is a LangGraph graph built with `deepagents` in
[twin_deep.py](twin-engine/src/twin_agent/twin_deep.py). Each step alternates
between "call the model" and "run the tools it asked for".

- **Checkpoint.** After every step, LangGraph saves the graph's whole state
  (messages, todos, files) to Postgres, keyed by the thread. If the process
  dies, invoking the graph again on that thread continues from the last
  checkpoint.
- **Interrupt.** A graph node can call `interrupt(payload)`. The graph stops,
  saves a checkpoint, and returns saying it was interrupted. Resuming with
  `Command(resume=value)` continues from exactly that point, with `value` as
  the result. Twin's approval gates are interrupts: "the twin wants to post
  this Slack message, approve?".
- **Run statuses.** `agent_runtime` keeps one `runs` row per turn:
  - `CREATED`: the row exists and nothing has run yet;
  - `RUNNING`: the graph is executing;
  - `WAITING`: interrupted. `wait_reason` says why: `TOOL_APPROVAL` for a
    gate, `EXTERNAL_EVENT` for word from outside;
  - `COMPLETED`, `FAILED`, `CANCELLED`.

  Only `RunStore.transition` may change a status, using compare-and-swap
  ("move from RUNNING to COMPLETED, only if it is still RUNNING").
- **`Runtime`**
  ([runtime.py](twin-engine/src/agent_runtime/runtime.py)) is the class that
  runs a turn:
  - `run` creates the row, moves it to RUNNING, resolves the tools, executes
    the graph and settles the row ([runtime.py:177](twin-engine/src/agent_runtime/runtime.py#L177));
  - `resume` continues a WAITING run with an answer, or a RUNNING run whose
    process died;
  - `cancel` stops a run and repairs the thread ([runtime.py:355](twin-engine/src/agent_runtime/runtime.py#L355)).

  None of this changed in the rebuild. It is wrapped whole inside a Temporal
  activity.

### 2.3 Redis Streams and Server-Sent Events

**Redis Stream.** An append-only log stored in Redis. `XADD key * field value`
appends an entry and returns its id, such as `1727190000000-0` (milliseconds,
then a counter). `XREAD BLOCK 10000 STREAMS key <id>` returns every entry
*after* `<id>`, or waits up to 10 s for one. `MAXLEN ~ 10000` trims old
entries. Unlike pub/sub, entries **stay**, so a reader that was away can ask
for what it missed.

**SSE (Server-Sent Events).** A long-lived HTTP response of lines like:

```
id: 1727190000000-0
event: frame
data: {"type":"token","text":"Hel"}

```

The browser's `EventSource` reads it. When the connection drops,
`EventSource` reconnects by itself and sends the header
`Last-Event-ID: <last id it saw>`. Put Redis Stream ids in the `id:` field and
reconnecting becomes exact: the server resumes the stream from that id.

### 2.4 ACP and JSON-RPC

**JSON-RPC 2.0** is a simple message format sent as one JSON object per line:

- a **request** has `id`, `method` and `params`, and expects a reply;
- a **response** has the same `id` and either `result` or `error`;
- a **notification** has `method` but no `id`, and expects no reply.

Either side can send requests.

**ACP (Agent Client Protocol)** is a JSON-RPC protocol for driving a coding
agent. dsh speaks it over its stdin and stdout. The parts Twin uses:

| Direction | Message | Meaning |
| --- | --- | --- |
| Twin → dsh | `initialize` | Handshake |
| Twin → dsh | `session/new` / `session/resume` | Open a conversation in `/workspace` |
| Twin → dsh | `session/set_config_option` | Choose the model |
| Twin → dsh | `session/prompt` | Give it work. Its **response** arrives only when the whole prompt is finished, with a `stopReason` |
| Twin → dsh | `session/cancel` (notification) | Stop the prompt in flight |
| dsh → Twin | `session/update` (notification) | Progress: message or thought chunks, tool calls starting and finishing, token usage |
| dsh → Twin | `session/request_permission` (request) | "May I run this?" with options. Twin must respond |

### 2.5 Container hardening terms

- **Capabilities.** Linux splits root's powers into about 40 capabilities
  (mount filesystems, change network settings, trace processes and so on).
  `CapDrop: ALL` removes every one, so even a root process inside the
  container can do very little.
- **`no-new-privileges`.** A program can't gain privileges by running a setuid
  binary.
- **Read-only root filesystem.** The image can't be modified. Only mounted
  volumes and a `tmpfs` (an in-memory filesystem) at `/tmp` are writable.
- **cgroup limits.** Caps on memory, CPU and process count. A fork bomb or a
  memory leak hits the box's limit, not the host's.
- **Init.** A tiny PID 1 that reaps "zombie" child processes left behind by
  background servers.
- **gVisor (`runsc`).** An optional runtime that puts a user-space kernel
  between the container and the host kernel. It is configurable here but not
  used on macOS.
- **Landlock.** A Linux feature that lets a process restrict which paths it
  (and its children) may touch. dsh uses it for its own sandbox, which gives a
  second layer inside the container.

### 2.6 HMAC and AES-GCM

- **HMAC** combines a secret key and a message into a short tag. Only someone
  with the key can produce the right tag for a message. Twin gives each box a
  token `<project id>.<HMAC(project id)>`: the proxies can check it without a
  database, and a box can't forge one for another project.
- **AES-GCM** is authenticated encryption. It hides the data and detects any
  tampering. It needs a unique random **nonce** for each message. Temporal
  payloads are sealed with it.

### 2.7 git over HTTP and pkt-lines

`git fetch` and `git push` over HTTPS use "smart HTTP":

- a `GET .../info/refs?service=git-upload-pack` (fetch) or
  `?service=git-receive-pack` (push) request;
- then a `POST .../git-upload-pack` or `.../git-receive-pack` carrying the data.

A push body starts with **pkt-lines**. Each line starts with four hex digits
giving its length (including those four), then the text. The push's commands
come first, one per ref: `<old sha> <new sha> <ref name>`. The first command
also carries capabilities after a NUL byte. The line `0000` ends the list, and
the packfile follows. Reading those first few lines tells you exactly which
branches a push will change, before anything reaches GitHub.

---

## 3. Journey A: a chat message

You type "hello" in a **new chat** and press Enter. Here is everything that
happens, in order.

### A1. The browser sends it

A new chat has no thread id yet. `useSendMessage`
([entities/messages/client.ts:62](twin-frontend/entities/messages/client.ts#L62))
posts `{ prompt }` through the Next.js API route to the backend. For an
existing chat it also sends `engineThreadId`.

```ts
// twin-frontend/entities/messages/client.ts:84-87
const result = await sendMessage({
  prompt,
  ...(threadId === undefined ? {} : { engineThreadId: threadId }),
});
```

When the answer comes back for a new chat, it navigates to `/chat/<id>`
([client.ts:99](twin-frontend/entities/messages/client.ts#L99)). The new page
shows your message straight away as an "optimistic" message, before any server
confirms it ([thread-state.ts:38](twin-frontend/components/features/chat/thread-state.ts#L38)).

### A2. The backend checks you and forwards the message

`sendMessage` in
[twin-threads.ts:201](twin-backend/apps/backend/src/routes/twin-threads.ts#L201):

1. `commanding` resolves who you are, and the twin you act as.
2. The body is validated against the shared contract (`sendMessageRequest`).
3. If a thread id is named, it asks the engine whether the thread is yours.
   Otherwise a 404.
4. It calls the engine's `startTurn` with the request's IP.

Every engine call carries identity headers, built in
[engine-http.ts:31-36](twin-backend/apps/backend/src/twin/engine-http.ts#L31):

- `x-twin-account`, `x-twin-company` and `x-twin-company-slug`;
- `x-twin-connector-key`, the account's own twin-backend API key, which the
  twin uses to call MCP tools as you;
- the relay secret as a bearer token.

> **Why doesn't the backend fetch memories for the twin?** It used to rank
> your message against your memory and hand the result over. Now the twin has
> memory tools and decides for itself whether it needs history
> ([twin-threads.ts:223-228](twin-backend/apps/backend/src/routes/twin-threads.ts#L223)).

### A3. The engine API admits the request and builds the tenant

`POST /internal/turns` is in
[inbound.py:156](twin-engine/src/twin_relay/inbound.py#L156). First,
`admitted` ([guard.py:71](twin-engine/src/twin_relay/guard.py#L71)):

```python
# twin-engine/src/twin_relay/guard.py:71-83
def admitted(request: Request, authorization: str | None) -> None:
    """Raise unless this request is the connector service's."""
    if request.headers.get("origin") is not None:
        raise HTTPException(status_code=403, detail="this relay does not serve browsers")
    offered = (
        authorization[len(BEARER) :] if authorization and authorization.startswith(BEARER) else ""
    )
    # Constant time: a secret compared with `==` leaks its prefix to a caller
    # who can time the answer.
    if not hmac.compare_digest(offered, request.app.state.secret):
        raise HTTPException(...)
```

- **An `Origin` header means a browser.** Browsers always send one on
  cross-origin requests, and the engine only serves the backend.
- **`compare_digest` takes the same time whether the first character or the
  last is wrong.** With `==`, an attacker could measure response times and
  guess the secret one character at a time.

Then:

- `acting_for` ([guard.py:118](twin-engine/src/twin_relay/guard.py#L118))
  turns the account header into a twin id.
- `tenant_for` ([guard.py:124](twin-engine/src/twin_relay/guard.py#L124))
  builds a `Tenant`: account, company, slug, the connector key, and the
  filesystem root. It is built from the request and **never from the
  environment**, which is what lets one process serve many companies safely.

The route creates a thread id if there isn't one, and composes the messages. A
turn started by an *event* gets a leading "situation" block, but a normal
message doesn't.

### A4. The message becomes a signal to the chat's workflow

```python
# twin-engine/src/twin_relay/inbound.py:189-199
    # A signal to the thread's workflow, started if none is running (spec
    # 2026-09-23 §6.1). A thread already answering queues this message rather
    # than refusing it, which is what lets the composer stay open.
    await _threads(request).send(
        thread_id=thread_id,
        twin_id=str(twin_id),
        message=Message(
            text=body.prompt, tenant=spec_of(tenant), model=body.model, composed=composed
        ),
    )
    return {"engineThreadId": thread_id}
```

- `spec_of` ([guard.py:148](twin-engine/src/twin_relay/guard.py#L148)) turns
  the `Tenant` into a `TenantSpec` ([wire.py:36](twin-engine/src/twin_workflows/wire.py#L36)),
  dropping the filesystem root. Each worker knows its own root, and a path
  from one machine means nothing on another.
- `Message` ([wire.py:59](twin-engine/src/twin_workflows/wire.py#L59)) is a
  plain dataclass: the text, the tenant, the model, and an optional `event`
  (set only on task reports; see B17).

`Threads.send` ([client.py:92](twin-engine/src/twin_workflows/client.py#L92)):

```python
# twin-engine/src/twin_workflows/client.py:92-100
    async def send(self, *, thread_id: str, twin_id: str, message: Message) -> None:
        await self._client.start_workflow(
            ThreadWorkflow.run,
            args=[ThreadStart(thread_id=thread_id, twin_id=twin_id, agent_id=self._agent_id), None],
            id=workflow_id(thread_id),
            task_queue=TASK_QUEUE,
            start_signal="message",
            start_signal_args=[message],
        )
```

This is start-with-signal (see 2.1). For a new chat, Temporal creates the
workflow `thread:<id>` and delivers the `message` signal before the workflow's
code runs. For an existing chat it just delivers the signal. The engine
returns **202** straight away. It doesn't wait for the twin.

> **Why the engine answers before anything runs.** A turn can take minutes.
> Holding an HTTP request open that long breaks on every proxy and deploy.
> The caller gets the thread id and subscribes to the live stream instead.

> **Why encryption is needed here.** `TenantSpec` carries your connector key.
> Temporal stores every signal argument in its history database. Without the
> codec (A15) your key would sit there as plain text.

### A5. What the workflow holds

[thread.py:102-113](twin-engine/src/twin_workflows/thread.py#L102):

```python
class ThreadWorkflow:
    @workflow.init
    def __init__(self, start: ThreadStart, carried: list[Message] | None = None) -> None:
        self._start = start
        self._inbox: list[Message] = list(carried or [])
        self._tenant: TenantSpec | None = self._inbox[-1].tenant if self._inbox else None
        self._decision: Decision | None = None
        self._notice: Notice | None = None
        self._stopping = False
        self._running: workflow.ActivityHandle[TurnOutcome] | None = None
        self._adopted: TurnOutcome | None = None
        self._state = ThreadState()
```

| Field | Meaning |
| --- | --- |
| `_inbox` | Messages waiting for a turn. `carried` refills it after a continue-as-new |
| `_tenant` | The latest tenant seen. The newest command always wins, so a rotated key is used on the next turn |
| `_decision`, `_notice` | An approval answer, or word from outside, for a parked run |
| `_stopping` | A stop was asked for |
| `_running` | The activity in flight, so `stop` can cancel it |
| `_adopted` | A parked run this workflow didn't start but must now manage (A12) |
| `_state` | What the `state` query reports: `phase` (`idle`, `working`, `needs_you` or `waiting`), `run_id`, `queued`, `turns` |

The signal handlers ([thread.py:116-153](twin-engine/src/twin_workflows/thread.py#L116))
only change this state:

- `message` appends to `_inbox`.
- `decide` records a decision only if `decision.run_id` is the run the thread
  is parked on. A late decision (the gate was already answered another way) is
  ignored rather than resuming something that has moved on.
- `notify` does the same for outside word.
- `stop` sets `_stopping` and cancels the running activity.

### A6. The loop

```python
# twin-engine/src/twin_workflows/thread.py:160-181
    async def run(self, start: ThreadStart, carried: list[Message] | None = None) -> None:
        del start, carried  # held by `__init__`, which Temporal calls with the same arguments
        while True:
            try:
                await workflow.wait_condition(
                    lambda: bool(self._inbox) or self._adopted is not None, timeout=IDLE
                )
            except TimeoutError:
                return
            self._stopping = False
            if self._adopted is not None:
                adopted, self._adopted = self._adopted, None
                await self._park(adopted)
            else:
                taken = next_batch(self._inbox)
                batch, self._inbox = self._inbox[:taken], self._inbox[taken:]
                await self._turn(batch)
            self._state.phase = "idle"
            self._state.turns += 1
            if self._state.turns >= TURNS_PER_RUN:
                await workflow.wait_condition(workflow.all_handlers_finished)
                workflow.continue_as_new(args=[self._start, self._inbox])
```

Line by line:

1. **Wait for work.** `IDLE` is 7 days
   ([thread.py:58](twin-engine/src/twin_workflows/thread.py#L58)). After a week
   of silence the workflow simply ends. The chat's history isn't in the
   workflow; it's in the LangGraph checkpoint and the `runs` table. So your
   next message starts a fresh workflow with the same id, and the twin
   remembers everything.
2. **Reset `_stopping`.** A stop applies to the turn it was sent during, not
   to the next one.
3. **Adopted or normal.** Adoption is explained in A12.
4. **Take a batch.** `next_batch` decides how many queued messages go into
   this turn (section 4.3).
5. **Continue-as-new every 100 turns** (`TURNS_PER_RUN`,
   [thread.py:60](twin-engine/src/twin_workflows/thread.py#L60)). This keeps the
   history small. `all_handlers_finished` first lets any signal handler
   finish, so no signal is lost in the hand-over. The inbox is carried over.

### A7. Starting the turn

```python
# twin-engine/src/twin_workflows/thread.py:183-199
    async def _turn(self, batch: list[Message]) -> None:
        start, last = self._start, batch[-1]
        outcome = await self._execute(
            "run_turn",
            TurnInput(
                thread_id=start.thread_id,
                twin_id=start.twin_id,
                agent_id=start.agent_id,
                turn_id=str(workflow.uuid4()),
                messages=merged(batch),
                tenant=last.tenant,
                model=last.model,
                origin=origin_of(batch),
                events=[m.event for m in batch if m.event and _from_task(m)],
            ),
        )
        await self._park(outcome)
```

- **`turn_id=str(workflow.uuid4())`** is the most important line for crash
  safety. `workflow.uuid4()` is deterministic: on replay it produces the same
  value. So if the activity is retried, the retry carries the **same**
  `turn_id` and can find the run its dead predecessor started (A9).
- **`messages=merged(batch)`** joins the batch into one user message (4.3).
- **`tenant=last.tenant`** and **`model=last.model`**: the newest message's
  settings win.
- **`origin`** and **`events`** mark a turn started by a task's report (B17).

`_execute` ([thread.py:271](twin-engine/src/twin_workflows/thread.py#L271))
starts the activity:

```python
# twin-engine/src/twin_workflows/thread.py:278-299 (abridged)
        self._state.phase = "working"
        self._running = workflow.start_activity(
            name,
            argument,
            result_type=TurnOutcome,
            start_to_close_timeout=TURN_LIMIT,      # 1 hour
            heartbeat_timeout=HEARTBEAT,            # 30 seconds
            retry_policy=RETRY,                     # 2s, x2, max 1 min, 8 attempts
            cancellation_type=workflow.ActivityCancellationType.WAIT_CANCELLATION_COMPLETED,
        )
        try:
            outcome = await self._running
        except ActivityError as error:
            if not isinstance(error.cause, CancelledError):
                workflow.logger.error("turn activity %s gave up: %s", name, error.cause)
            return None
        finally:
            self._running = None
        self._state.run_id = outcome.run_id
        return outcome
```

- **`TURN_LIMIT` = 1 hour** is a ceiling, not a target. Coding runs in tasks,
  so no legitimate turn comes close.
- **`HEARTBEAT` = 30 s.** The activity beats every 5 s
  ([turns.py:49](twin-engine/src/twin_workflows/turns.py#L49)). Silence for 30 s
  means the worker is dead, and the activity moves to another.
- **`RETRY`** ([thread.py:62](twin-engine/src/twin_workflows/thread.py#L62))
  lists `non_retryable_error_types`: an unknown agent or a tenant outside its
  workspace won't succeed on the ninth try, so those fail at once.
- **`WAIT_CANCELLATION_COMPLETED`**: after a stop, the next turn mustn't start
  until the stopped one has finished repairing the thread.
- **A failure is logged, not raised.** If the workflow itself failed, every
  later message in the chat would be refused. The run row already records
  FAILED.

### A8. The worker runs the activity

`engine-worker` is [twin_workflows/__main__.py](twin-engine/src/twin_workflows/__main__.py).
It builds one `Runtime`, a checkpointer, a `Drainer` (the projector) and a
`FrameBatcher`, then polls `twin-turns` with up to 20 activities at once
(`CONCURRENCY`). Each turn mostly waits on a model, so the limit is about
memory, not CPU. On SIGTERM it stops taking work and gives running turns 30 s
(`DRAIN`) to finish.

### A9. `run_turn`: three cases, one of them a crash

```python
# twin-engine/src/twin_workflows/turns.py:77-105 (abridged)
    async def run_turn(self, turn: TurnInput) -> TurnOutcome:
        twin_id = uuid.UUID(turn.twin_id)
        tenant = self.tenant(turn.tenant)
        existing = await self._run_for(turn.thread_id, twin_id, turn.turn_id)
        if existing is None:
            work = self._runtime.run(
                agent_id=turn.agent_id, twin_id=twin_id,
                input={"messages": turn.messages},
                metadata={"turn_id": turn.turn_id, "origin": turn.origin,
                          **({"events": turn.events} if turn.events else {})},
                thread_id=turn.thread_id, model=turn.model, tenant=tenant,
            )
        elif existing.status is RunStatus.RUNNING:
            logger.info("turn %s found RUNNING after a lost worker; continuing it", turn.turn_id)
            work = self._runtime.resume(run_id=existing.id, twin_id=twin_id, tenant=tenant)
        else:
            return await self._outcome(existing)
        appearing = asyncio.create_task(self._project_once_created(turn, twin_id))
        try:
            run = await self._beating(work, turn.thread_id, twin_id, turn.turn_id)
        finally:
            appearing.cancel()
        return await self._outcome(run)
```

`_run_for` ([turns.py:190](twin-engine/src/twin_workflows/turns.py#L190))
looks through the thread's runs for one whose `metadata.turn_id` matches.

| What it finds | What it means | What it does |
| --- | --- | --- |
| Nothing | First attempt | `Runtime.run`, which stores `turn_id` in the row's metadata |
| A RUNNING run | A previous attempt's worker died mid-turn | `Runtime.resume`, continuing from the last checkpoint |
| A settled or WAITING run | A previous attempt finished, but its result was lost | Nothing; just report it |

This is what makes the activity safe to retry: it never starts a second run
for the same turn. It is also the whole replacement for the old
`stranded.py`, which found such runs by sweeping every 5 minutes for runs stuck
over 2 hours.

`tenant` ([turns.py:64](twin-engine/src/twin_workflows/turns.py#L64))
rebuilds a real `Tenant` from the `TenantSpec`, adding this worker's own
filesystem root.

### A10. `_beating`: heartbeats, and two kinds of cancellation

```python
# twin-engine/src/twin_workflows/turns.py:135-157
    async def _beating(self, work, thread_id, twin_id, turn_id) -> Run:
        task = asyncio.ensure_future(work)
        beat = asyncio.create_task(_heartbeat())
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            if activity.in_activity() and activity.is_worker_shutdown():
                # A deploy, not a person: leave the row RUNNING and the
                # checkpoint intact for the retry on the next worker.
                task.cancel()
                raise
            await asyncio.shield(self._cancel(task, thread_id, twin_id, turn_id))
            raise
        finally:
            beat.cancel()
```

- **`asyncio.shield(task)`.** When Temporal cancels the activity, the
  `await` raises `CancelledError`, but the turn itself keeps running. That
  matters because `Runtime.cancel` has to find the turn still holding its
  thread to stop it properly: interrupt the model, close open tool calls, and
  charge what it spent.
- **Two kinds of cancellation:**
  - **The worker is shutting down** (a deploy). The row is left RUNNING on
    purpose, so the retry on the next worker resumes it (the RUNNING case in
    A9).
  - **A person pressed stop.** `_cancel` calls `Runtime.cancel`, which
    repairs the thread and settles the row CANCELLED. The result is then
    projected.
- **`_heartbeat`** ([turns.py:228](twin-engine/src/twin_workflows/turns.py#L228))
  calls `activity.heartbeat()` every 5 s. This is also how a cancellation
  reaches the activity: Temporal delivers it in its reply to a heartbeat.

### A11. Inside `Runtime.run`, briefly

[runtime.py:177](twin-engine/src/agent_runtime/runtime.py#L177), unchanged by
the rebuild:

1. `Run.create` builds the row, and nothing executes before it exists.
2. `_claim` marks the thread as executing *in this process*
   ([runtime.py:465](twin-engine/src/agent_runtime/runtime.py#L465)). It still
   exists, but it is no longer what keeps two machines apart: the workflow id
   does that now. It remains a local guard, and it is how `cancel` finds the
   asyncio task to interrupt.
3. The row moves from CREATED to RUNNING.
4. `_with_tools` resolves the account's MCP tools using the tenant's
   connector key.
5. A spend meter is attached. `langgraph_executor.execute` runs the graph with
   the checkpointer and the tracer's callbacks.
6. `_settle` writes the outcome: COMPLETED with the answer, WAITING with a
   `wait_reason`, or FAILED.

### A12. Frames: how tokens reach Redis

While the graph runs, LangChain calls callback handlers on every token and
tool event.

1. `RelayTracer.callback_handler`
   ([tracer.py:137](twin-engine/src/twin_relay/tracer.py#L137)) returns a
   `FrameHandler`, which turns those callbacks into small JSON **frames**
   (token, tool start, tool end, title) and hands them to the `FrameBatcher`.
2. `FrameBatcher` ([tracer.py:55](twin-engine/src/twin_relay/tracer.py#L55))
   buffers frames and flushes every **0.25 s** or every **200 frames**,
   whichever comes first (`FLUSH_SECONDS`, `FLUSH_FRAMES`). One Redis call per
   token would be thousands of calls per turn.
3. `RedisSink.push_frames`
   ([sink.py:73](twin-engine/src/twin_relay/sink.py#L73)) groups the batch by
   thread and runs one Lua script per thread:

```lua
-- twin-engine/src/twin_relay/sink.py:38-48
local count = #ARGV - 2
local seq = redis.call('INCRBY', KEYS[1], count) - count
for i = 3, #ARGV do
  redis.call('XADD', KEYS[2], 'MAXLEN', '~', ARGV[1], '*', 'seq', seq, 'frame', ARGV[i])
  seq = seq + 1
end
redis.call('EXPIRE', KEYS[1], ARGV[2])
redis.call('EXPIRE', KEYS[2], ARGV[2])
return seq
```

- **`INCRBY` reserves a block of sequence numbers** for this batch, and each
  frame gets the next one. A Lua script runs atomically in Redis, so no other
  writer's frames can land between reserving a number and appending its frame.
  With two separate calls, two workers could interleave and number frames out
  of order.
- **`KEYS[1]` is the counter `twin:frames:{<thread>}:seq`, and `KEYS[2]` the
  stream `twin:frames:{<thread>}`** ([sink.py:51](twin-engine/src/twin_relay/sink.py#L51)).
  The **braces** are Redis Cluster "hash tags": only the part inside them
  decides which server holds a key. That puts the counter and the stream on
  the same server, which a script touching both requires.
- **`MAXLEN ~ 10000`**, about one long turn, is what a reconnect can replay.
  **`EXPIRE` 2 days**: a reader away longer than that reads the projection
  instead.
- **An `asyncio.Lock`** ([sink.py:71](twin-engine/src/twin_relay/sink.py#L71))
  exists because batches are sent as separate asyncio tasks, and two batches
  for one thread could otherwise reach Redis in the wrong order.
- **Failures are logged, not raised.** A lost batch costs a live view, never a
  record.

### A13. Projection: the chat tables

"Projection" means turning a run (a row plus a checkpoint) into what the page
draws: `chat_threads`, `chat_turns`, `chat_decisions`. It happens in three
places:

1. **As soon as the run row exists.** `_project_once_created`
   ([turns.py:174](twin-engine/src/twin_workflows/turns.py#L174)) polls for the
   new row at 0.05 s, 0.1 s, 0.2 s and so on, and projects it once found. A new
   chat's page subscribes the moment its message is accepted, and a thread with
   no projection refuses subscriptions. Without this, a new chat would be
   unreadable for its whole first turn.
2. **When the activity ends.** `_outcome`
   ([turns.py:202](twin-engine/src/twin_workflows/turns.py#L202)) projects the
   run it touched, then builds the `TurnOutcome`.
3. **A repair sweep in the engine API.** `_sweeping`
   ([twin_relay/__main__.py:138](twin-engine/src/twin_relay/__main__.py#L138))
   runs every 2 s to catch anything the activities missed. It must not run on
   every replica, so it runs under a leader lock:

```python
# twin-engine/src/twin_relay/leader.py:38-50 (abridged)
async def leading(engine: AsyncEngine, work: Callable[[], Awaitable[None]]) -> None:
    while True:
        try:
            async with engine.connect() as conn:
                held = await conn.scalar(_TRY, {"key": SWEEP_LOCK})   # pg_try_advisory_lock
                if held:
                    try:
                        await work()
                    finally:
                        await conn.execute(_RELEASE, {"key": SWEEP_LOCK})
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.warning("the background sweep stopped; retrying", exc_info=True)
        await asyncio.sleep(RETRY_SECONDS)
```

A Postgres **advisory lock** is a named lock (here the number
`0x7477_696E_0001`, "twin" in hex) held by a database connection. Only one
connection can hold it. If the leader dies, its connection closes and Postgres
releases the lock, and within 10 s another replica takes it.

> `modes.follow` ([modes.py:117](twin-engine/src/twin_relay/modes.py#L117)),
> which also runs every 2 s, is a different job. It keeps each worker's copy
> of the auto-mode switches (the chats where you turned approvals off) in step
> with the database, because the worker never receives the command that flips
> a switch.

### A14. The backend reads the stream; the browser keeps it open

**Backend.** The chat's stream route
([twin-threads.ts:156](twin-backend/apps/backend/src/routes/twin-threads.ts#L156))
decides where to start reading:

- `resumeFrom` ([twin-stream-writer.ts:20](twin-backend/apps/backend/src/twin-stream-writer.ts#L20))
  takes `Last-Event-ID` or `?after=`, but only if it looks like a stream id
  (`^\d+-\d+$`).
- Otherwise it starts after the newest entry, taken *before* the ownership
  check so nothing written during that check is lost.

It then starts a reader:

```ts
// twin-backend/apps/backend/src/twin-stream.ts:133-170 (abridged)
export function follow(redis, logger, key, after, deliver): () => void {
  const connection = redis.duplicate({ commandTimeout: BLOCK_MS + 5_000 });
  let last = after;
  let stopped = false;
  async function readOnce(): Promise<boolean> {
    const answer = await connection.xread('COUNT', BATCH, 'BLOCK', BLOCK_MS, 'STREAMS', key, last);
    const entries = (answer ?? []).flatMap(([, held]) => held as Entry[]);
    last = entries.at(-1)?.[0] ?? last;
    return deliver(entries);
  }
  ...
}
```

- **`redis.duplicate()`** gives each reader its own connection, because
  `XREAD BLOCK` holds a connection while it waits.
- **Blocks of 10 s, batches of 500.** A failed read is retried after 1 s.
- `readerSet` ([twin-stream.ts:181](twin-backend/apps/backend/src/twin-stream.ts#L181))
  tracks every reader so shutdown can stop them all.

`serveLive` ([twin-stream-writer.ts:47](twin-backend/apps/backend/src/twin-stream-writer.ts#L47))
holds the SSE response open:

- It sends a **named** `heartbeat` event, because `EventSource` ignores SSE
  comments and a quiet stream would look dead.
- It drops a reader whose buffer grows past the limit
  (`writeOrDisconnect`, [:33](twin-backend/apps/backend/src/twin-stream-writer.ts#L33)),
  since otherwise a slow client would grow the server's memory without bound.

**Browser.** `subscribe`
([entities/threads/socket.ts:66](twin-frontend/entities/threads/socket.ts#L66))
wraps `EventSource` with the retries it lacks:

- **It retries HTTP errors** every second, up to 30 times. `EventSource` only
  reconnects on a dropped socket, not on an error response, and a new chat's
  first subscribe can 404 before its projection exists.
- **It sweeps for silence.** A half-open connection (a closed laptop lid, a
  load balancer timeout) raises no error at all. Every frame and heartbeat
  pushes a deadline back; after 2.5 heartbeats of silence (`STALE_AFTER_MS`,
  [frames.ts:29](twin-frontend/entities/threads/frames.ts#L29)) it rebuilds
  from the projection and reopens. The check also runs on tab-visible and
  network-online events, because hidden tabs throttle timers.
- **It tracks `lastEventId`** ([socket.ts:123](twin-frontend/entities/threads/socket.ts#L123)),
  so a manual reopen asks for `?after=<id>` (`resumingAfter`,
  [frames.ts:53](twin-frontend/entities/threads/frames.ts#L53)).
- `missedFrames` ([frames.ts:47](twin-frontend/entities/threads/frames.ts#L47))
  compares the frames' `seq` numbers to spot a gap.

### A15. The codec

```python
# twin-engine/src/twin_workflows/codec.py:33-71 (abridged)
def derive_key(secret: str) -> bytes:
    return hashlib.sha256(b"twin-temporal-codec\x00" + secret.encode()).digest()

class EncryptionCodec(converter.PayloadCodec):
    def _seal(self, payload: Payload) -> Payload:
        nonce = os.urandom(_NONCE)                       # 12 random bytes, new every time
        sealed = self._aead.encrypt(nonce, payload.SerializeToString(), None)
        return Payload(
            metadata={"encoding": ENCODING, "encryption-key-id": self._key_id},
            data=nonce + sealed,
        )

    def _open(self, payload: Payload) -> Payload:
        if payload.metadata.get("encoding") != ENCODING:
            return payload
        held = payload.metadata.get("encryption-key-id", b"")
        if held != self._key_id:
            raise ValueError("... the relay secret differs between processes")
        ...
```

- **The key is derived from the relay secret** the engine already has, with a
  label (`twin-temporal-codec\0`) so it can never equal a key derived from the
  same secret for another purpose. The box tokens use a different label.
- **A fresh nonce for every payload**, as AES-GCM requires.
- **A key id in the metadata.** A process with the wrong secret gets a clear
  error ("the relay secret differs between processes"), not a baffling
  decryption failure.
- **`data_converter`** ([codec.py:74](twin-engine/src/twin_workflows/codec.py#L74))
  plugs the codec into Temporal. `connect`
  ([client.py:80](twin-engine/src/twin_workflows/client.py#L80)) uses it, so
  every process that talks to Temporal seals and opens payloads the same way.

---

## 4. Journey A, continued: approvals, stops and queued messages

### 4.1 An approval gate

Suppose the twin decides to post in Slack. That tool is in `APPROVAL_GATES`
([gates.py:67](twin-engine/src/twin_agent/gates.py#L67)), so:

1. **The graph interrupts.** deepagents' human-in-the-loop middleware raises
   an interrupt before the tool runs. The checkpoint is saved, and
   `Runtime._settle` marks the run WAITING with
   `wait_reason = TOOL_APPROVAL`.
2. **The activity returns a `TurnOutcome`.**
   `outcome_of` ([turns.py:208](twin-engine/src/twin_workflows/turns.py#L208))
   fills in the pending interrupt ids (`asked`) and, for an outside wait, a
   topic (`wait_topic`). `waiting` is true.
3. **The workflow parks.** `_park` loops on `_settle` while the outcome is
   waiting ([thread.py:201](twin-engine/src/twin_workflows/thread.py#L201)):

```python
# twin-engine/src/twin_workflows/thread.py:219-245
        external = outcome.wait_topic is not None
        self._state.phase = "waiting" if external else "needs_you"
        with contextlib.suppress(TimeoutError):
            await workflow.wait_condition(
                lambda: (
                    self._decision is not None
                    or self._notice is not None
                    or self._stopping
                    or (not external and self._person_waiting())
                ),
                timeout=EXTERNAL_WAIT if external else None,
            )
        decision, self._decision = self._decision, None
        notice, self._notice = self._notice, None
        if self._stopping or (decision is not None and decision.decision != "approve"):
            return await self._stop(outcome.run_id)
        if decision is not None:
            return await self._resume(outcome, {"decision": "approve"}, decision.tenant)
        if notice is not None:
            return await self._resume(outcome, notice.payload, notice.tenant or self._tenant)
        if external:
            timed_out = {"timedOut": True, "topic": outcome.wait_topic, "key": outcome.wait_key}
            return await self._resume(outcome, timed_out, self._tenant)
        # Superseded by a new message.
        return await self._stop(outcome.run_id)
```

Nothing runs while it waits: no process, no memory, no connection. It
wakes for one of four reasons:

| It wakes because | It does |
| --- | --- |
| You approved | `resume_turn` with `{"decision": "approve"}` |
| You rejected, or pressed stop | `stop_turn`. Rejecting *stops* the turn rather than telling the model it was refused, which would cost another model call for the twin to explain itself |
| You sent a new message (`_person_waiting`) | `stop_turn` on the parked run. The loop then takes your message as the next turn. **You moved on, so the twin moves on.** This is the "never awaiting" rule |
| For an outside wait: 6 h passed (`EXTERNAL_WAIT`) | Resume, telling the run it timed out. This replaces the old `waits.reap` sweeper |

`_person_waiting` ([thread.py:247](twin-engine/src/twin_workflows/thread.py#L247))
looks only for messages **without** an `event`. A task's automatic report
arriving during a gate doesn't count as you moving on.

4. **Your click reaches the engine.** `POST /internal/runs/{run_id}/decision`
   ([inbound.py:202](twin-engine/src/twin_relay/inbound.py#L202)):

```python
# twin-engine/src/twin_relay/inbound.py:228-237
    # Checked here because a signal cannot say no: a decision on a run that has
    # already settled is a person answering a question that is no longer open,
    # and a 202 would tell them it landed.
    if run.status is not RunStatus.WAITING:
        raise HTTPException(status_code=409, detail=f"run {run_id} is {run.status}, not waiting")
    # Before the signal, not after: resuming consumes the gate, so a decision
    # written afterwards would be racing the turn it answered.
    await decisions.mark_decided(request.app.state.engine, run_id, _answered(body.decision))
    decision = Decision(run_id=run_id, decision=body.decision, tenant=spec_of(tenant))
    await _delivered(request, run, lambda: _threads(request).decide(run.thread_id, decision))
```

   - **409 up front**, because a signal has no way to say "too late".
   - **The decision row is written first**, so a page that reloads right now
     already shows the gate answered.
   - **`_delivered`** ([inbound.py:132](twin-engine/src/twin_relay/inbound.py#L132))
     sends the signal. If no workflow exists for the thread, it first starts
     one with the `adopt` signal (4.4), then sends the decision.

5. **The resume is safe to retry.** `_resume` passes `answering=outcome.asked`.
   `resume_turn` ([turns.py:108](twin-engine/src/twin_workflows/turns.py#L108))
   delivers the answer only if the run is still waiting on exactly those
   interrupts (`_still_asking`,
   [turns.py:198](twin-engine/src/twin_workflows/turns.py#L198)). A retry after
   the answer was already delivered finds something else pending, and does
   nothing.

### 4.2 Stop

The stop button calls `POST /internal/threads/{id}/stop`
([inbound.py:412](twin-engine/src/twin_relay/inbound.py#L412)), which sends the
`stop` signal. The handler sets `_stopping` and cancels the running activity.
`_beating` sees a cancellation that is **not** a shutdown and calls
`Runtime.cancel`. `WAIT_CANCELLATION_COMPLETED` makes the workflow wait for
that cleanup before the loop continues. If the turn was parked, `_settle` sees
`_stopping` and runs `stop_turn`
([turns.py:126](twin-engine/src/twin_workflows/turns.py#L126)).

### 4.3 Messages sent while the twin is busy

1. The composer is never disabled. The stop button only shows when the box is
   empty, so what you type is sent, not blocked
   ([composer.tsx:106-108](twin-frontend/components/features/chat/composer.tsx#L106)).
2. The message goes through A1–A4 as usual. Start-with-signal finds the
   workflow running, so the `message` handler just appends it to `_inbox`. The
   running turn isn't interrupted.
3. The page marks it "queued"
   ([user-message.tsx:42](twin-frontend/components/features/chat/user-message.tsx#L42),
   decided by `queuedBehind`,
   [thread-state.ts:159](twin-frontend/components/features/chat/thread-state.ts#L159)).
4. When the turn ends, the loop runs `next_batch`, then `merged`:

```python
# twin-engine/src/twin_workflows/thread.py:72-98 (abridged)
def merged(batch: list[Message]) -> list[dict]:
    leading = [part for message in batch for part in message.composed if part["role"] == "system"]
    text = "\n\n".join(message.text for message in batch)
    return [*leading, {"role": "user", "content": text}]

def _from_task(message: Message) -> bool:
    return (message.event or {}).get("kind") == "task"

def origin_of(batch: list[Message]) -> str:
    return "task" if all(_from_task(message) for message in batch) else "person"

def next_batch(inbox: list[Message]) -> int:
    first = _from_task(inbox[0])
    return next((i for i, message in enumerate(inbox) if _from_task(message) != first), len(inbox))
```

   - **`next_batch`** takes the longest run at the front of the inbox that
     shares an origin: all yours, or all task reports. If the inbox is
     `[you, you, report, you]`, the next turn gets your two messages, the one
     after it gets the report, and then your last message.
   - **`merged`** joins the batch into **one** user message, separated by
     blank lines.

> **Why merge?** The projection finds a turn's messages by slicing the
> transcript at its last human message. Two human messages in one turn would
> put the first under the previous turn on screen. And "oh, and also…"
> belongs with what you just said.

> **Why never mix a report and your message?** The chat draws a turn as
> either "you said" or "a task reported". A mix couldn't be drawn honestly, and
> the twin would struggle to tell which part was you.

### 4.4 Adoption

Some runs are parked with no workflow behind them: a turn started through the
dev harness, or one parked before this runtime existed. A decision for such a
run would have nowhere to go. `Threads.adopt`
([client.py:102](twin-engine/src/twin_workflows/client.py#L102)) starts the
thread's workflow with the `adopt` signal, which sets `_adopted`
([thread.py:136](twin-engine/src/twin_workflows/thread.py#L136)). The loop
then calls `_park` on that run as if it had parked it itself.

---

## 5. Journey B: a coding task

You type: *"make a live chat app (simple one), realtime chat should work, for
db you can use sqlite now"*. Steps A1–A10 happen exactly as before. This
journey picks up inside the twin's turn.

### B1. The twin decides this is a task

Four things decide where the code goes:

1. **Its prompt.** The coding section of
   [twin_deep.md:14](twin-engine/src/twin_agent/prompts/twin_deep.md#L14) is
   headed *"Code: show it, write a little, hand over the rest"*. The test it
   gives is **where the code has to end up**:
   - a snippet they only want to read stays in the reply;
   - a small change to one source file, already clear, the twin writes itself;
   - everything else is a coding task: more than one file, code it would have
     to read or debug first, anything that has to install, build, run or pass
     a test.

   A live chat app is several files that have to install and run, so it is a
   task. The prompt then gives the steps:
   - check `list_tasks` for an existing project to continue;
   - call `start_task` with a title and a brief;
   - say what you started in one line and end your turn.
2. **One line naming the tools on this run.** `coding_line`
   ([coding.py:24](twin-engine/src/twin_agent/coding.py#L24)) goes **last**
   in the system prompt, states the limit in numbers and names `start_task`
   exactly. The model reads the
   end of a prompt most closely, and a rule that doesn't name the real tool is
   easy to miss among forty tool descriptions.
3. **Enforcement.** `Authorship`
   ([authorship.py:302](twin-engine/src/twin_agent/authorship.py#L302)) lets
   the twin write **one source file a turn**: a new file of at most 80 lines,
   or at most 30 changed lines of edits (`FILES_PER_TURN`, `NEW_FILE_LINES`,
   `EDIT_LINES`, [authorship.py:89](twin-engine/src/twin_agent/authorship.py#L89)).
   - A write that would take the turn past that is struck out, and so is any
     `execute` that runs a build, a test, a package manager or git.
   - The model is told to start a task instead (`_ROUTE`,
     [authorship.py:132](twin-engine/src/twin_agent/authorship.py#L132)).
   - What the turn has already written is counted from its own messages
     (`_written_before`, [authorship.py:256](twin-engine/src/twin_agent/authorship.py#L256)),
     so nothing extra has to survive checkpoints.
   - The check runs in `after_model`, before the tool node ever sees the call.
     The struck call stays on the message with its refusal beside it, so the
     model reads the refusal and carries on instead of the turn ending
     silently.
   - A run with no engine to start tasks on keeps the same limit and is told
     no task can be started (`_NO_ROUTE`).
4. **No Claude Code.** The twin holds none of the `claude-code` connector's
   tools: `twin_deep_graph` drops them before building the graph
   ([twin_deep.py:140](twin-engine/src/twin_agent/twin_deep.py#L140)). A
   person's Claude Code connection stays theirs and is never a route for the
   twin's work.

### B2. `start_task`

`task_tools` ([tasks.py:127](twin-engine/src/twin_agent/tasks.py#L127)) gives
the twin six tools, all built on `EngineApi`
([engine_api.py:32](twin-engine/src/twin_agent/engine_api.py#L32)), which calls
the engine's own HTTP routes with the tenant's headers. The twin's worker never
touches the task tables directly. That keeps one owner for them (the engine
API), one place that enforces the quota, and one place that talks to Temporal.

```python
# twin-engine/src/twin_agent/tasks.py:157-188 (abridged)
def _starter(engine: EngineApi) -> Any:
    async def start_task(runtime: ToolRuntime, title: str, brief: str, *,
                         project_id: str | None = None, repo: str | None = None,
                         mode: str = "auto") -> str:
        sent = {"thread_id": _thread(runtime), "title": title, "brief": brief, "mode": mode}
        ...
        status, body = await _safely(engine, "POST", "/internal/tasks", json=sent)
        if status == httpx.codes.ACCEPTED:
            return (
                f"Started task {body['taskId']} in project {body['projectId']}. Its card is in "
                "the chat and shows its progress; say what you started in one line and end "
                "your turn. You will be told when it finishes or needs an answer."
            )
        if status == httpx.codes.TOO_MANY_REQUESTS:
            return f"Not started: {_detail(body)}. Tell them, and offer to start it after."
        if status == httpx.codes.CONFLICT:
            return (f"Not started: {_detail(body)}. Send that task the change with "
                    "`message_task`, or stop it first.")
        return _failed(START_TOOL, status, body)
```

- **The thread id comes from the graph's runtime config** (`_thread`), not
  from the model, so the model can't send a report to the wrong chat.
- **Every answer is an instruction.** A tool result is the model's next
  input, so "say what you started in one line and end your turn" steers it
  better than a bare 202.
- **`mode="auto"`** means dsh's own permission prompts are answered
  automatically. `ask` would put each one to you (B11).

The other five tools are `list_tasks`, `get_task`, and three signalling tools
(`message_task`, `answer_task`, `stop_task`) built from one table, `_COMMANDS`
([tasks.py:120](twin-engine/src/twin_agent/tasks.py#L120)).

### B3. `POST /internal/tasks`: quota, project, row, workflow

[task_routes.py:72](twin-engine/src/twin_relay/task_routes.py#L72):

1. **Admit and identify**, as in A3.
2. **Quota.** `store.live_count` counts this twin's tasks in `queued`,
   `working` or `needs_input`. At `TWIN_CODE_MAX_LIVE_TASKS` (default 3) the
   route answers **429** with a sentence the twin can repeat.
3. **Project.** `_project` ([task_routes.py:197](twin-engine/src/twin_relay/task_routes.py#L197)):
   - With a `project_id`: check it's this twin's, then **close** its ready
     tasks (`_closed`, [:227](twin-engine/src/twin_relay/task_routes.py#L227)),
     because a ready task still holds the box.
   - With a `repo`: find or create the one project for that repository
     (section 7).
   - Otherwise, as here: `create_project` with `kind=app`, `source="new"`.
     The id is `prj_<32 hex>` ([store.py:51](twin-engine/src/twin_code/store.py#L51)).
4. **Task row.** `create_task` inserts `task_<32 hex>` with status `queued`,
   the default model `deepseek-v4-pro`
   ([task_routes.py:43](twin-engine/src/twin_relay/task_routes.py#L43)) and
   mode `auto`.

   The table has a **partial unique index**:

```python
# twin-engine/src/twin_db/models/tasks.py:79-84
        Index(
            "uq_tasks_one_live_per_project",
            "project_id",
            unique=True,
            postgresql_where=text("status IN ('queued', 'working', 'needs_input')"),
        ),
```

   At most one *live* task per project. Two agents in one working tree would
   race on its files, its git index and its ports. Enforcing this in the
   database means no code path can break it. A second start on the same
   project raises `IntegrityError`, which becomes a **409** naming the task
   that holds the project.

5. **Workflow.** `Tasks.start` ([client.py:147](twin-engine/src/twin_workflows/client.py#L147))
   starts `CodeTaskWorkflow` with id `task:<task id>` on queue `twin-code`,
   with a `TaskStart` ([wire.py:160](twin-engine/src/twin_workflows/wire.py#L160))
   carrying the ids, title, brief, mode, model and tenant.
6. **202** `{taskId, projectId, status: "queued"}`.

### B4. The twin ends its turn, and the chat shows a card

The twin replies with one line, and the turn settles COMPLETED and is
projected. The frontend finds which task cards to draw with `taskIdsIn`
([lib/code-tasks.ts:105](twin-frontend/lib/code-tasks.ts#L105)): it reads the
`task_<hex>` id out of each `start_task` call's output, plus the task ids of
any report events that started the turn. Each id becomes a `<TaskCard>`
([turn-view.tsx:211](twin-frontend/components/features/chat/turn-view.tsx#L211)).

**The chat is now free.** Everything below happens in the background.

### B5. `CodeTaskWorkflow`: its state and its loop

[code_task.py:76](twin-engine/src/twin_workflows/code_task.py#L76). The state:

| Field | Meaning |
| --- | --- |
| `_inbox` | Follow-ups waiting for the next round (from the twin, the panel, or PR review) |
| `_answer` | The chosen option for a pending permission question |
| `_stopping`, `_closing` | A stop was asked for; or the task is being closed because a new task needs the box |
| `_failed` | Why it failed, if it did |
| `_progress` | How far dsh's stream has been read, and what is in flight (B9) |
| `_pull`, `_heard` | Whether its work is a pull request, and up to what time its feedback has been read |

The signals ([code_task.py:95-112](twin-engine/src/twin_workflows/code_task.py#L95)):

- `message(text)` appends to `_inbox`;
- `answer(TaskAnswer)` sets `_answer`;
- `stop()` sets `_stopping` and cancels the running activity;
- `close()` sets `_closing`.

The loop:

```python
# twin-engine/src/twin_workflows/code_task.py:119-134
    async def run(self, start: TaskStart) -> None:
        progress = await self._act("open_task", start, result_type=Progress)
        self._progress = progress or self._progress
        prompt: str | None = start.brief
        while progress is not None and not self._stopping:
            outcome = await self._prompt(PromptInput(start=start, progress=progress, text=prompt))
            if self._stopping or outcome is None:
                break
            finished = await self._act("finish_task", start, result_type=dict)
            self._pull = bool((finished or {}).get("prUrl"))
            if self._pull and not self._heard:
                self._heard = workflow.now().isoformat()
            self._state.status = "ready"
            await self._report("ready")
            prompt, progress = await self._next(start, outcome.progress)
        await self._stopped()
```

In words: open the box, then repeat **prompt → finish → report "ready" → wait
for a follow-up** until there's no follow-up, a stop, or a failure. Then end.

Every activity goes through `_act`:

```python
# twin-engine/src/twin_workflows/code_task.py:236-260 (abridged)
        self._running = workflow.start_activity(
            name, argument,
            task_queue=CODE_QUEUE,
            result_type=result_type,
            start_to_close_timeout=_LIMITS[name],
            heartbeat_timeout=timedelta(seconds=60) if name == "prompt_task" else None,
            retry_policy=RETRY,
            cancellation_type=workflow.ActivityCancellationType.WAIT_CANCELLATION_COMPLETED,
        )
        try:
            return await self._running
        except ActivityError as error:
            if isinstance(error.cause, CancelledError):
                return None
            workflow.logger.error("task activity %s gave up: %s", name, error.cause)
            if name not in ("report_task", "stop_task"):
                self._failed = str(error.cause)
                self._stopping = True
            return None
```

- **Time limits differ by activity** (`_LIMITS`,
  [code_task.py:60](twin-engine/src/twin_workflows/code_task.py#L60)):
  `open_task` 10 min (a clone can be slow), `prompt_task` **3 h**,
  `finish_task` 5 min, and the rest a minute or two.
- **Only `prompt_task` heartbeats (every 5 s, timeout 60 s)**, because it is
  the only long one. The others are short enough that their start-to-close
  timeout catches a dead worker.
- **An activity that gives up after its retries (6 attempts) fails the
  task**, with the reason, at the loop's next check. The exceptions are
  `report_task` and `stop_task`: a failed chat message mustn't turn a stopped
  task into a failed one.

### B6. `open_task`: make the box, open the agent

[work.py:80](twin-engine/src/twin_code/work.py#L80):

```python
# twin-engine/src/twin_code/work.py:80-106 (abridged)
    async def open_task(self, start: TaskStart) -> Progress:
        box = await self._boxes.ensure(start.project_id, start.twin_id)
        await store.set_box(self._engine, start.project_id, box_id=box, state=BoxState.RUNNING)
        head = await self._head(start.project_id)
        link = await Link.open(self._boxes, start.project_id, head)
        try:
            await handshake(link)
            session_id = await self._session(link, start)
            await link.request("session/set_config_option",
                {"sessionId": session_id, "configId": "model", "value": model_option(start.model)})
            await workspace.prepare(self._boxes, await workspace.repo_for(self._engine, start), start)
            await workspace.install_skills(self._boxes, self._engine, start)
            base = (await self._boxes.run(start.project_id, ["sh", "-c", inspect.BASELINE])).output
            await store.set_task(self._engine, start.task_id, status=TaskStatus.WORKING,
                                 session_id=session_id, base_sha=...)
            await self._events.append(start.task_id, "status", {"status": "working"})
            return Progress(seq=link.seq)
        finally:
            await link.close()
```

Step by step:

1. **`ensure`**: make or start the box. The details are in section 6.1.
2. **`_head`** runs `acpd status` in the box and reads the last line number
   acpd has logged. Attaching from there means a fresh attach doesn't replay
   an earlier task's lines.
3. **`Link.open`** attaches to dsh through acpd (6.3), from line `head`.
4. **`handshake`** sends `initialize`.
5. **`_session`** resumes the task's session if it has one (a box woken after
   sleeping), or opens a new one with `session/new` and `cwd=/workspace`. If
   dsh refuses a resume because the session is already live in this process,
   that's fine: either way the session is usable.
6. **Set the model.** `model_option` produces
   `["deepseek-official","deepseek-v4-pro"]` as **compact JSON**. dsh compares
   the string exactly, and a space after the comma is refused
   ([acp.py:117](twin-engine/src/twin_code/acp.py#L117)).
7. **`prepare`** does nothing for an app. For a repository it clones and
   branches (7.1).
8. **`install_skills`** writes the account's skills into the box (9.3).
9. **`BASELINE`** ([inspect.py:19](twin-engine/src/twin_code/inspect.py#L19))
   makes sure `/workspace` is a git repository with at least one commit,
   creating "Twin: starting point" if needed, and prints `HEAD`. That commit
   is `base_sha`, the point every later diffstat and patch is measured from.
10. **Set `working`**, and log a `status` event.
11. **Return `Progress(seq=link.seq)`**: where the stream has been read to.

### B7. `prompt_task`: give dsh the work

[work.py:129](twin-engine/src/twin_code/work.py#L129). There are three
cases, decided by the `Progress` passed in and the heartbeat:

```python
# twin-engine/src/twin_code/work.py:129-169 (abridged)
    async def prompt_task(self, prompt: PromptInput) -> PromptOutcome:
        start = prompt.start
        progress = resumed(prompt.progress)
        row = await store.task(self._engine, start.task_id)
        link = await Link.open(self._boxes, start.project_id, progress.seq)
        try:
            if progress.pending_id is not None and prompt.option_id is not None:
                # (1) answering a permission question
                await link.respond(progress.pending_id,
                    {"outcome": {"outcome": "selected", "optionId": prompt.option_id}})
                ...
            elif progress.prompt_id is None:
                # (2) a new prompt
                text = prompt.text or ""
                # Before the prompt, not after: the LLM proxy charges - and so
                # admits - only a project's live task, and a follow-up to a
                # ready one was refused as "no task is running here".
                await store.set_task(self._engine, start.task_id, status=TaskStatus.WORKING)
                await self._events.append(start.task_id, "prompt", {"text": text})
                if not await store.has_prompted_before(self._engine, start.task_id):
                    repo = await workspace.repo_for(self._engine, start)
                    branch = repos.branch_of(start.task_id)
                    text = workspace.opening(repo, branch) + text
                prompt_id = await link.notify("session/prompt",
                    {"sessionId": row.session_id, "prompt": [{"type": "text", "text": text}]})
                progress = Progress(seq=link.seq, prompt_id=prompt_id)
            # (3) otherwise: a retry of a prompt already in flight - send nothing
            return await Follower(self._engine, self._events, link, start).follow(progress)
        finally:
            await link.close()
```

- **`resumed(...)`** ([follow.py:146](twin-engine/src/twin_code/follow.py#L146))
  returns the *last heartbeat's* `Progress` if this attempt is a retry.
  Temporal hands heartbeat details to the next attempt as plain dicts, so it
  rebuilds the dataclass.
- **Case 3 is crash recovery.** A retry finds `prompt_id` already set in the
  heartbeat, so it **doesn't send the prompt again**. dsh is still working
  under acpd; the retry just reattaches from the line the dead worker reached
  and keeps following.
- **The first prompt gets a preamble.** `opening`
  ([workspace.py:76](twin-engine/src/twin_code/workspace.py#L76)) prepends
  `PREAMBLE` ([workspace.py:38](twin-engine/src/twin_code/workspace.py#L38)) for
  an app, or repository rules for a repo. `PREAMBLE` tells the agent:
  - background any long-running server, bound to `0.0.0.0` (so the preview
    gateway can reach it);
  - allow `.preview.localhost` hosts (Vite otherwise refuses unknown hosts);
  - the internet is only package registries and GitHub reads;
  - `/workspace` starts as an empty git repository;
  - commit as you go;
  - finish with a summary.
- **`notify` rather than `request`.** `session/prompt`'s response only
  arrives when the whole prompt is done, possibly an hour later. `notify`
  sends it and returns the request id; the Follower watches for the response
  with that id.

### B8. The Follower: reading dsh's stream

```python
# twin-engine/src/twin_code/follow.py:47-73
    async def follow(self, progress: Progress) -> PromptOutcome:
        timeline = Timeline()
        reached = [progress]
        beating = asyncio.create_task(_beat(reached))
        try:
            while True:
                frame = await self.link.next_frame()
                line = self.link.seq
                progress = Progress(seq=line, prompt_id=progress.prompt_id)
                if frame.is_response and str(frame.body.get("id")) == progress.prompt_id:
                    await self._emit(timeline.flush(), line)
                    return await self._ended(frame.body, line)
                if frame.method == "session/update":
                    update = (frame.body.get("params") or {}).get("update") or {}
                    await self._emit(timeline.fold(update, line), line)
                elif frame.is_request and frame.method == "session/request_permission":
                    await self._emit(timeline.flush(), line)
                    asked = await self._asked(timeline, frame.body, progress)
                    if asked is not None:
                        return asked
                reached[0] = Progress(seq=timeline.committed(line), prompt_id=progress.prompt_id)
        except asyncio.CancelledError:
            if not activity.is_worker_shutdown():
                await asyncio.shield(self._cancel())
            raise
        finally:
            beating.cancel()
```

Three kinds of frame matter:

1. **The response to our prompt.** Flush any text being gathered, then
   `_ended` ([follow.py:75](twin-engine/src/twin_code/follow.py#L75)):
   - An `error` in the response means a model call dsh couldn't make, such as
     the LLM proxy's 402 at the spend ceiling. The outcome is `failed` with the
     message, and the task fails with that reason. It must not read as finished
     work.
   - Otherwise the outcome is `ended`, with dsh's `stopReason`.
2. **`session/update`**: fold it into timeline events (B10) and store or
   stream them (`_emit`).
3. **`session/request_permission`**: B11.

**Heartbeats.** `_beat` ([follow.py:159](twin-engine/src/twin_code/follow.py#L159))
sends `reached[0]` to Temporal every 5 s. That value is
`timeline.committed(line)`, not simply `line`. If the agent is halfway through
a paragraph, the paragraph hasn't been stored yet (text is stored whole, B10).
A retry that started after the current line would miss its beginning, so the
heartbeat records the line *before the paragraph began*, and a retry re-reads
the whole paragraph.

**Cancellation.** A shutdown leaves dsh working, for the next worker. A
person's stop calls `_cancel`, which sends `session/cancel` so dsh stops
spending, and logs `status: stopping`.

### B9. `Progress`, the thread through every retry

```python
# twin-engine/src/twin_workflows/wire.py:174-186 (docstring shortened to comments)
@dataclass(frozen=True, slots=True)
class Progress:
    seq: int = 0                    # the last acpd line handled
    prompt_id: str | None = None    # the session/prompt request in flight
    pending_id: str | None = None   # the permission request waiting for an answer
```

The workflow passes it into every activity, and `prompt_task` puts it in every
heartbeat. From it a retried activity knows three things:

- **where to reattach**: `seq`;
- **whether a prompt is already running**: `prompt_id`, so it doesn't send a
  duplicate;
- **which question is open**: `pending_id`, so an answer goes to the right
  request.

### B10. The timeline: turning updates into events

`Timeline.fold` ([timeline.py:54](twin-engine/src/twin_code/timeline.py#L54))
takes one ACP update and returns the events it produces.

| ACP update | Events |
| --- | --- |
| `agent_message_chunk` / `agent_thought_chunk` | Nothing stored yet. The chunk is added to the text being gathered, and a **live** `delta` event is streamed so the panel can show typing |
| any other update, after text | The gathered text is **flushed** as one stored `message` or `thought` event first |
| `tool_call` | A stored `step` with `status: running` and a one-line `about`. If the tool is `todo_write`, also a `plan` event with the whole checklist (ACP sends no plans of its own) |
| `tool_call_update` completed/failed | A stored `step` with `done` or `failed` and the output, clipped to 2,000 characters |
| `usage_update` | A live `usage` event (not stored) |

```python
# twin-engine/src/twin_code/timeline.py:80-90
    def _chunk(self, kind: str, text: str, line: int) -> list[Event]:
        if not text:
            return []
        events = self.flush() if kind != self.writing else []
        if self.writing is None:
            self.since = line
        self.writing = kind
        self.written.append(text)
        if kind == "message":
            self.said.append(text)
        return [*events, Event("delta", {"kind": kind, "text": text}, live=True)]

    # timeline.py:68-70
    def committed(self, line: int) -> int:
        return self.since - 1 if self.writing is not None else line
```

- **Why gather text?** The first version stored one row per chunk: hundreds
  of rows per paragraph. Now a paragraph is one row, and the chunks go out
  live with no row.
- **`since`** remembers the line where the current text began, which is what
  `committed` needs (B8).
- **`about`** ([timeline.py:129](twin-engine/src/twin_code/timeline.py#L129))
  picks the line a person reads: dsh's own `description` if it gave one, else
  the tool plus its file, path, pattern or command.
- **`_updated`** ([timeline.py:107](twin-engine/src/twin_code/timeline.py#L107))
  only adds `tool` and `about` if it saw the call start. A reader that
  reattached mid-call didn't, and the frontend then keeps what the start event
  said (`stepOf`, 8.3).

**Storing events.** `Events.append`
([store.py:221](twin-engine/src/twin_code/store.py#L221)):

```python
# twin-engine/src/twin_code/store.py:221-247 (abridged)
        async with self._engine.begin() as conn:
            seq = (await conn.scalar(
                select(func.coalesce(func.max(_EVENTS.c.seq), 0) + 1).where(_EVENTS.c.task_id == task_id)
            )) or 1
            # RETURNING, not rowcount: through the async driver a skipped
            # ON CONFLICT insert still reported a row (measured 2026-09-23).
            written = await conn.scalar(
                pg_insert(_EVENTS)
                .values(task_id=task_id, seq=seq, type=kind, payload=payload, source=source)
                .on_conflict_do_nothing(index_elements=["task_id", "source"],
                                        index_where=_EVENTS.c.source.is_not(None))
                .returning(_EVENTS.c.seq)
            )
        if written is None:
            return None
        await self._publish(task_id, {"seq": seq, "type": kind, "payload": payload})
        return seq
```

- **`seq` = max + 1**, with no lock. That is safe because only one activity at
  a time writes a task's events: one workflow owns the task.
- **`source`** is `"<acpd line>:<index within that line>"`, set by `_emit`
  ([follow.py:96](twin-engine/src/twin_code/follow.py#L96)). The partial
  unique index `uq_task_events_source` (migration 0013) turns a second write of
  the same event into a no-op. A worker that re-reads lines after a restart
  therefore never duplicates the timeline.
- **`RETURNING`, not `rowcount`.** Through the async driver, a skipped
  `ON CONFLICT` insert still reported one affected row. `RETURNING` returns
  nothing when nothing was inserted, which can't lie.
- **`_publish`** ([store.py:258](twin-engine/src/twin_code/store.py#L258))
  appends the event to the task's Redis Stream `twin:task:{<id>}` (capped at
  5,000 entries, kept 7 days), on a best-effort basis: the table is the
  record.
- **`stream`** ([store.py:249](twin-engine/src/twin_code/store.py#L249))
  publishes a live-only event (`delta`, `usage`) with **no `seq`**, because it
  isn't part of the record.

### B11. When dsh asks permission

dsh sends `session/request_permission` when it wants to do something outside
its sandbox policy. The request names only a tool-call id, so
`question` ([timeline.py:153](twin-engine/src/twin_code/timeline.py#L153))
looks up the earlier `tool_call` for the command and dsh's justification, and
builds a card: `callId`, `tool`, `about`, `command`, `justification`, `wants`,
and `options` (each with an `id`, a `label` and a `kind` such as `allow_once`).

`_asked` ([follow.py:106](twin-engine/src/twin_code/follow.py#L106)):

- **In `auto` mode**, it picks the `allow_once` option, responds to dsh, logs
  an `approved` event, and keeps following.
- **In `ask` mode**, it sets the task to `needs_input` with the question in
  `pending`, logs a `question` event, and **returns** `needs_input`, with
  `pending_id` recorded in `Progress`. The activity ends.

Why end the activity instead of waiting inside it? A person may take hours
(M0 measured 2 h 18 min, and dsh held the request the whole time). An activity
waiting that long would hold a worker slot and a Docker stream. The workflow
can wait for free.

The workflow side is `_prompt`
([code_task.py:136](twin-engine/src/twin_workflows/code_task.py#L136)): on
`needs_input` it reports to the chat (B17), waits with no timeout for the
`answer` signal, then runs `prompt_task` again with `option_id`. That is case 1
in B7: respond to the open request, log `answered`, and keep following.

How an answer arrives:

- **the twin** calls `answer_task`, when it's confident from what it knows
  about you;
- **you** click an option on the task page (`TaskQuestion`,
  [task-question.tsx:10](twin-frontend/components/features/code-tasks/task-question.tsx#L10)).

Either way it becomes `POST /internal/tasks/{id}/answer`
([task_routes.py:161](twin-engine/src/twin_relay/task_routes.py#L161)) and then
the `answer` signal.

### B12. Every model call dsh makes goes through the LLM proxy

Inside the box, dsh thinks it's talking to DeepSeek at `DEEPSEEK_BASE_URL`,
which is `http://llm-proxy:8300`, using the key `DEEPSEEK_API_KEY`. That key is
really the **box token**:

```python
# twin-engine/src/twin_code/tokens.py:20-37 (abridged)
_DOMAIN = b"twin-box-token\x00"

def _mac(secret: str, project_id: str) -> str:
    key = hashlib.sha256(_DOMAIN + secret.encode()).digest()
    return hmac.new(key, project_id.encode(), hashlib.sha256).hexdigest()[:40]

def mint(secret: str, project_id: str) -> str:
    return f"{project_id}.{_mac(secret, project_id)}"

def project_of(secret: str, token: str) -> str | None:
    project_id, _, mac = token.rpartition(".")
    if not project_id or not hmac.compare_digest(mac, _mac(secret, project_id)):
        return None
    return project_id
```

For each call, `Proxy.completions`
([llm_proxy.py:124](twin-engine/src/twin_code/llm_proxy.py#L124)):

1. **`charged_task`** ([:110](twin-engine/src/twin_code/llm_proxy.py#L110)):
   - check the token and get the project;
   - find the project's **live** task, or answer 403 "no task is running
     here";
   - if its `cost_usd` has reached `TWIN_CODE_MAX_COST_USD` (default $2),
     answer **402**.
2. **`upstream_body`** ([:55](twin-engine/src/twin_code/llm_proxy.py#L55))
   translates DeepSeek's request into OpenRouter's:
   - map model names (`deepseek-v4-pro` → `deepseek/deepseek-v4-pro`);
   - `thinking` / `reasoning_effort` → `reasoning`;
   - rename `reasoning_content` in past messages;
   - add `usage: {include: true}` so OpenRouter reports the cost.
3. **Forward with the real key**, streaming.
4. **`_relay`** ([:150](twin-engine/src/twin_code/llm_proxy.py#L150)) passes
   each SSE line back, translating `reasoning` into `reasoning_content`, and
   **charges the task when the usage chunk passes**:

```python
# twin-engine/src/twin_code/llm_proxy.py:160-171
        try:
            async for line in upstream.aiter_lines():
                sent = line
                if line.startswith("data: ") and line[6:].strip() not in ("", "[DONE]"):
                    chunk = json.loads(line[6:])
                    if chunk.get("usage"):
                        cost, used = spent(chunk["usage"])
                        await store.charge(self._engine, task, cost_usd=cost, tokens=used)
                    sent = "data: " + json.dumps(downstream_chunk(chunk))
                yield sent + "\n"
        finally:
            with anyio.CancelScope(shield=True):
                await upstream.aclose()
```

> **The bug this shape fixes.** Charging used to happen after the loop. But
> dsh hangs up as soon as it reads `[DONE]`. Starlette then cancels this
> generator, and under anyio *every* `await` after a cancellation raises
> again, so the charge never ran. The first live task was charged for 1 of its
> first 35 calls. The usage chunk arrives just before `[DONE]`, so charging it
> as it passes always happens. The cleanup `aclose()` runs inside a
> **shielded** scope for the same anyio reason.

> **Why a task must be `working` before its prompt.** The proxy only serves a
> project's *live* task. A ready task that got a follow-up used to stay
> `ready` until the prompt was sent, so its first model call was refused. That
> is why B7 sets `working` before `session/prompt`.

`store.charge` ([store.py:162](twin-engine/src/twin_code/store.py#L162)) adds
to `cost_usd` and `tokens` in a single `UPDATE ... SET cost_usd = cost_usd + x`,
so two concurrent calls can't lose each other's charge.

### B13. Every download goes through Squid

`npm install ws better-sqlite3` inside the box reads `HTTPS_PROXY=http://egress:3128`.
npm sends `CONNECT registry.npmjs.org:443` to Squid, and Squid applies
[squid.conf](twin-engine/sandbox/egress/squid.conf) top to bottom:

```
acl allowed dstdomain .npmjs.org .npmjs.com .yarnpkg.com
acl allowed dstdomain .pypi.org files.pythonhosted.org pypi.python.org
acl allowed dstdomain github.com codeload.github.com .githubusercontent.com
acl allowed dstdomain deb.debian.org nodejs.org .astral.sh .crates.io
acl allowed dstdomain proxy.golang.org sum.golang.org
acl private_dst dst 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10
acl private_dst dst ::1 fc00::/7 fe80::/10
http_access deny private_dst
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow allowed
http_access deny all
```

Squid stops at the first `http_access` rule that matches, so the order is the
policy:

1. never to a private, loopback or metadata address;
2. only ports 80 and 443;
3. HTTPS tunnels (`CONNECT`) only to 443;
4. the allowlist;
5. everything else is refused.

- **Squid resolves the name itself** and checks the resolved address against
  `private_dst`. An allowed-looking name that resolves to `169.254.169.254`
  (the cloud metadata service) or `10.x` is still refused.
- **`.githubusercontent.com` is allowed** because packages such as
  `better-sqlite3` download prebuilt binaries from GitHub release assets. If
  that fails, the image has `build-essential` and Python, so node-gyp can
  compile from source.
- **Every denial is logged** in the `egress` container's `access.log`.

The box's `NO_PROXY` lists the LLM and git proxies, so dsh reaches them
directly on the sandbox network. Sending them through Squid would fail, since
their addresses are private.

### B14. `finish_task`: what came out of the round

[work.py:171](twin-engine/src/twin_code/work.py#L171), run after the prompt
ends:

1. **`_summary`** ([work.py:216](twin-engine/src/twin_code/work.py#L216))
   takes the agent's **last** message since the prompt. Its earlier messages
   are running narration ("Let me scaffold…", "Build passes."). Joined, they
   read as a transcript, where the twin wants a result.
2. **`_wrap_up`** ([work.py:198](twin-engine/src/twin_code/work.py#L198)),
   using `workspace.wrap_up` ([workspace.py:138](twin-engine/src/twin_code/workspace.py#L138)):
   - **`COMMIT`** ([repos.py:122](twin-engine/src/twin_code/repos.py#L122))
     commits anything left uncommitted, as "Twin: finish the task".
   - **`patch_command`** ([repos.py:111](twin-engine/src/twin_code/repos.py#L111))
     makes the patch since `base_sha` using a **throwaway index**:
     `GIT_INDEX_FILE=/tmp/twin-patch-index`, then `git add -A`, then
     `git diff --cached`. Untracked files appear in the patch without touching
     the agent's real index. The patch is clipped and stored as a `changes`
     event for the Changes tab.
   - For a repository it also pushes and opens a PR (section 7).
3. **The diffstat** (`diffstat_command` and `parse_shortstat`,
   [inspect.py:26](twin-engine/src/twin_code/inspect.py#L26)) uses the same
   throwaway-index trick, giving `{files, added, removed}` for the card.
4. **Finding the preview.** `LISTENING` reads `/proc/net/tcp` and `tcp6` for
   sockets in state `0A` (LISTEN). `preview_port`
   ([inspect.py:63](twin-engine/src/twin_code/inspect.py#L63)) prefers common
   dev-server ports (5173, 3000, 4321, 8000, 8080, 4173, 5000), then any port
   from 1025 to 32767. It asks the box, not the agent: whether a server is
   actually listening is a fact, not a claim. Nothing else in the box listens
   on TCP (acpd uses a unix socket), so any open port is the app.
5. **The preview URL** is the template
   `http://{box}.{port}.preview.localhost:47620` (`preview_for`,
   [boxes.py:87](twin-engine/src/twin_code/boxes.py#L87)), with `{box}` being
   the project id's 32 hex characters.
6. **Mark `ready`** with the summary, diffstat, preview URL and no pending
   question, and log a `ready` event.

### B15. The preview gateway

```
# twin-engine/sandbox/preview/Caddyfile:16-24
:80 {
	@box header_regexp box Host ^([0-9a-f]{32})\.([0-9]{2,5})\.preview\.localhost(:[0-9]+)?$
	handle @box {
		reverse_proxy twinbox-{re.box.1}:{re.box.2}
	}
	handle {
		respond "No preview here." 404
	}
}
```

- **`*.localhost` always resolves to your own machine** in browsers, so no DNS
  setup is needed locally. Port 47620 on the host maps to Caddy's :80.
- **The regex is the security.** Only 32 hex characters and a 2–5 digit port
  are accepted, so the name can only become `twinbox-<hex>:<port>`. You can't
  write `postgres.5432.preview.localhost`.
- **`reverse_proxy` passes WebSocket upgrades through.** Your chat app's
  realtime connection and the dev server's hot reload both work.
- **The 32-hex id is the capability**: unguessable, but not signed.

### B16. Idle, sleep and follow-ups

After reporting, the workflow calls `_next`
([code_task.py:165](twin-engine/src/twin_workflows/code_task.py#L165)):

```python
# twin-engine/src/twin_workflows/code_task.py:169-182 (comments added)
        if not await self._arrives(IDLE):                 # 30 minutes
            await self._act("sleep_box", start, ...)      # stop the container, keep volumes
            self._state.status = "ready"
            if not await self._arrives(RETAIN) or self._closing:   # 7 days
                return None, None                         # → the task ends as done
            woke = await self._act("open_task", start, ...)        # start the box again
            progress = woke if woke is not None else progress
        if self._closing:
            return None, None
        if self._stopping:
            return None, progress
        text = "\n\n".join(self._inbox)
        self._inbox.clear()
        return text, progress
```

- **A follow-up** is a `message` signal. It comes from:
  - the twin's `message_task`;
  - the task page's steer box (`TaskSteer`);
  - a line comment in the Changes tab;
  - PR review (7.4).

  All queued follow-ups are joined into the next round's prompt.
- **`sleep_box`** ([work.py:289](twin-engine/src/twin_code/work.py#L289))
  stops the container after 30 idle minutes but keeps both volumes, so the
  next message wakes it exactly as it was, down to `node_modules` and dsh's
  session.
- **After 7 days** with nothing, the task ends as `done`. It is recorded, but
  not reported, because a chat message a week later would be noise.
- **`close`** ends a ready task when a new task starts on the same project,
  which keeps a single writer per project.

### B17. The report: the task comes back to the chat

`report_task` ([work.py:254](twin-engine/src/twin_code/work.py#L254)):

```python
        await self._threads.send(
            thread_id=start.thread_id,
            twin_id=start.twin_id,
            message=Message(
                text=reports.render(
                    row,
                    report.kind,
                    (await store.latest(self._engine, start.task_id, "prompt")).get("text"),
                    await store.latest(self._engine, start.task_id, "changes"),
                ),
                tenant=start.tenant,
                event=reports.event_of(row, report.kind),
            ),
        )
```

It's the **same** `Threads.send` your own messages use (A4). The difference is
`event = {"kind": "task", "taskId", "status", "title"}`
([reports.py:103](twin-engine/src/twin_code/reports.py#L103)). The text, from
`render` ([reports.py:38](twin-engine/src/twin_code/reports.py#L38)), is
written **to the twin**, not to you:

```
[Task update: ready] "Live chat app" (task task_…)
What it was asked this round: "make a live chat app (simple one), …"
(Sent by you with `message_task`, or by them in the task's own panel - either way, it was asked for.)
What the coding agent says it did: …
Changes: 9 files, +412 -0
Preview: http://<hex>.3000.preview.localhost:47620

This is an automatic update from a background task you started, not a message from the person.
Tell them what it did in a sentence or two and what they can do next - …
```

- **The request is always quoted.** Once, you steered a task from its panel;
  the report didn't say so, and the twin concluded the task was "making
  changes on its own" and stopped it.
- **"Not a message from the person"** stops the twin replying to the report
  as if you had written it.
- **The closing instruction differs by kind** (`_EXPECTED`,
  [reports.py:20](twin-engine/src/twin_code/reports.py#L20)). For
  `needs_input` it says: answer it yourself with `answer_task` if what you know
  about them makes the answer clear, otherwise ask them.

In the chat's workflow:

- the message joins `_inbox`;
- `next_batch` never mixes it with your messages;
- `origin_of` marks the turn `task`, and `_turn` copies the event into
  `TurnInput.events`, then into the run's metadata, then into
  `chat_turns.events` (migration 0012);
- the contract carries it to the page as `origin` and `events`
  ([twin.ts:190-208](twin-backend/packages/contracts/src/twin.ts#L190)).

The frontend's `Asked` ([turn-view.tsx:55](twin-frontend/components/features/chat/turn-view.tsx#L55))
draws a task-started turn with the task's card where your message would be.

### B18. Stopping or failing a task

`_stopped` ([code_task.py:216](twin-engine/src/twin_workflows/code_task.py#L216))
runs `stop_task` ([work.py:227](twin-engine/src/twin_code/work.py#L227)):

1. If a prompt is in flight, reattach.
2. Refuse any open question (outcome `cancelled`).
3. Send `session/cancel`.
4. Wait up to 30 s (`CANCEL_WAIT`) for the prompt's response.
5. Record `stopped`, `failed` or `done`, with the error.

For stopped and failed, it then reports.

---

## 6. Inside the box

### 6.1 Creating the container

`Boxes.ensure` ([boxes.py:135](twin-engine/src/twin_code/boxes.py#L135)):

1. Get the container `twinbox-<hex>` by name.
2. If Docker answers 404, create it with `_config`.
3. If it isn't running, start it and wait for `acpd status` to succeed (up to
   60 tries, half a second apart). A box counts as up only once its agent is.

```python
# twin-engine/src/twin_code/boxes.py:90-133 (abridged; the three trailing comments are added)
        host: dict[str, Any] = {
            "CapDrop": ["ALL"],
            "SecurityOpt": ["no-new-privileges"],
            "ReadonlyRootfs": True,
            "Tmpfs": {"/tmp": "rw,size=2g"},
            "Memory": 4 * GIB,
            "MemorySwap": 4 * GIB,
            "NanoCpus": 2_000_000_000,
            "PidsLimit": 1024,
            "Init": True,
            "NetworkMode": self._settings.network,            # twin-sandbox
            "RestartPolicy": {"Name": "unless-stopped"},
            "LogConfig": {"Type": "json-file", "Config": {"max-size": "10m", "max-file": "2"}},
            "Mounts": [
                {"Type": "volume", "Source": f"{name}-workspace", "Target": "/workspace"},
                {"Type": "volume", "Source": f"{name}-home", "Target": "/home/coder/.dsh"},
            ],
        }
        if self._settings.runtime:
            host["Runtime"] = self._settings.runtime               # "runsc" for gVisor
        return {
            "Image": self._settings.image,                         # twin-box:dev
            "Hostname": name,
            "Labels": {"twin.project": project_id, "twin.twin": twin_id},
            "Env": [
                f"DEEPSEEK_BASE_URL={self._settings.llm_url}",
                f"DEEPSEEK_API_KEY={mint(self._secret, project_id)}",
                *(f"{key}={proxy}" for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")),
                *(f"{key}={direct},localhost,127.0.0.1" for key in ("NO_PROXY", "no_proxy")),
            ],
            "HostConfig": host,
        }
```

| Setting | What it prevents or provides |
| --- | --- |
| `CapDrop: ALL` | No mounting, no network reconfiguration, no ptrace, no raw sockets |
| `no-new-privileges` | No escalation through setuid binaries |
| `ReadonlyRootfs` + 2 GB tmpfs `/tmp` | Nothing can change the image. Only `/workspace`, dsh's home and `/tmp` are writable |
| `MemorySwap` = `Memory` = 4 GiB | Swap is disabled, so a leak hits the limit instead of thrashing the host |
| `NanoCpus` 2e9 | Two CPUs |
| `PidsLimit` 1024 | A fork bomb stops at 1,024 processes |
| `Init` | Reaps zombie processes from backgrounded dev servers |
| `unless-stopped` | If dsh dies, acpd exits, and Docker restarts the box. `sleep_box` stops it on purpose, and it stays stopped |
| Log limit 2 × 10 MB | A chatty agent can't fill the disk |
| `twin.*` labels | The box can be traced back to its project and twin |
| Two volumes | The code and dsh's state survive the container being stopped or recreated |
| Env | Model and proxy settings. The only "secret" is the box token |

**Docker access is filtered.** `code-worker` reaches Docker through
`DOCKER_HOST=tcp://docker-proxy:2375`
([docker-compose.yml:459](docker-compose.yml#L459)). The proxy allows
`CONTAINERS`, `EXEC`, `VOLUMES` and `POST` and nothing else: no swarm, no
secrets, no system calls. Raw access to the Docker socket is effectively root
on the host, so no Python process holds it.

### 6.2 The image and the entrypoint

[sandbox/Dockerfile](twin-engine/sandbox/Dockerfile):

- **Base and toolchain:** `node:22-bookworm-slim`, plus `uv`, `git`,
  `build-essential` and Python.
- **dsh `0.1.5-rc.3`, pinned.** It must be at least 0.1.2-alpha.1, because
  CVE-2026-82533 was in dsh's *web* profile. The box only runs the ACP profile,
  which opens no HTTP listener at all.
- **User `coder` (uid 1001).**
- **Environment:** `DSH_HOME=/home/coder/.dsh` and
  `DSH_TELEMETRY_MODE=DISABLED`.
- **Every package cache is redirected** under `/workspace/.cache`
  (`npm_config_cache`, `UV_CACHE_DIR`, `PIP_CACHE_DIR` and so on). The root is
  read-only, so the default cache paths would fail. And a project's second
  task shouldn't download everything again.

[entrypoint.sh](twin-engine/sandbox/entrypoint.sh):

```sh
if [ ! -d "$DSH_HOME/profiles/twin" ]; then
  dsh --profile twin --from-default-profile acp --dump-config >/dev/null
fi
cd "$HOME"
exec python3 /opt/twin/acpd.py serve -- dsh --profile twin --patch /opt/twin/profile.patch.yml
```

- **Create the `twin` profile once**, from dsh's shipped `acp` profile, on the
  home volume.
- **`cd "$HOME"`, not `/workspace`.** dsh reads a `.env` file from the
  directory it starts in. Starting inside the project would let the project's
  own `.env` configure the agent.
- **`exec` acpd as the main process**, with dsh as its child.
- **The patch** ([profile/cordis.patch.yml](twin-engine/sandbox/profile/cordis.patch.yml))
  sets the provider to `deepseek-official` with model `deepseek-v4-pro`, and
  **disables dsh's web tools**. The egress allowlist would refuse them anyway,
  and a tool that always fails teaches the model to waste steps on it.

### 6.3 acpd: the supervisor that makes restarts free

**The problem.** dsh talks over stdin and stdout. If the process holding its
stdio dies, dsh dies too, and the prompt's work is lost (M0 check G5). Code
workers restart on every deploy.

**The fix.** acpd ([sandbox/acpd.py](twin-engine/sandbox/acpd.py), 164 lines,
standard library only) is the box's main process. It holds dsh's stdio for the
box's whole life, and workers attach to *acpd*, over a unix socket.

```python
# twin-engine/sandbox/acpd.py:65-81
    def pump_dsh(self) -> None:
        assert self.dsh.stdout is not None
        for line in self.dsh.stdout:
            with self.lock:
                self.seq += 1
                record = json.dumps({"seq": self.seq, "frame": _decoded(line)}) + "\n"
                self.log.write(record)
                if self.client is not None:
                    try:
                        self.client.sendall(record.encode())
                    except OSError:
                        # The worker went away mid-line. Nothing is lost: the
                        # record is logged, and the next attach replays it.
                        self.client = None
        # dsh has gone, and a box without its agent is not one: exit, and let
        # the code worker see the box stop and start it again.
        os._exit(self.dsh.wait() or 1)
```

- **Every line dsh writes gets a number** (`seq`), and is appended to
  `$DSH_HOME/acp.log` and sent to the attached client, if any.
- **`_last_seq`** reads the log at startup, so numbering carries on after a
  box restart and never repeats.
- **If dsh exits, acpd exits**, and the restart policy brings the box back.

`serve_client` ([acpd.py:83](twin-engine/sandbox/acpd.py#L83)) handles a
connection. The first line is the command:

- **`STATUS`** answers with `{"seq", "pid"}`. This is used by `_ready` and
  `_head`.
- **`FROM <n>`** is an attach. Under the lock:
  1. close any previous client, since there is one writer at a time, and two
     workers answering one prompt would be worse than either;
  2. replay every logged record with `seq > n`;
  3. only then become the live client.

  Holding the lock across the replay and the switch means no line can slip
  between them. After that it forwards the client's input lines to dsh's
  stdin.

The socket is `chmod 0600`. The socket and log live in `$DSH_HOME`, which
dsh's Landlock policy keeps the agent's own shell out of. That is defence in
depth, not a boundary: the agent runs as the same user.

**How the worker attaches.** `Boxes.attach`
([boxes.py:217](twin-engine/src/twin_code/boxes.py#L217)) runs
`python3 /opt/twin/acpd.py attach --from N` inside the box through Docker
`exec`, with stdin open. The `attach` subcommand
([acpd.py:136](twin-engine/sandbox/acpd.py#L136)) connects to the socket,
sends `FROM N`, and copies bytes both ways. Docker multiplexes the exec's
stdout and stderr, and `Stream`
([boxes.py:50](twin-engine/src/twin_code/boxes.py#L50)) keeps only stream 1
(stdout) and splits it into lines.

### 6.4 The ACP link

`Link` ([acp.py:54](twin-engine/src/twin_code/acp.py#L54)) is JSON-RPC over
that stream:

- **`next_frame`** reads a line, parses `{"seq", "frame"}`, updates
  `self.seq`, and **keeps every response** in `answered`, keyed by id.
- **`notify(method, params)`** sends a request with a fresh `uuid4().hex` id
  and returns the id without waiting.
- **`request`** is `notify`, then `answer_to(id)` with a 60 s timeout.
- **`answer_to`** reads frames until the response with that id has arrived,
  then returns its `result`, or raises `AgentError` on an `error`.
- **`respond`** answers a request *from* dsh (permission).

> **Why a uuid for every request id?** After a reattach, acpd replays old
> lines, including responses to requests some *earlier* worker sent. Ids that
> started at 1 in each worker would collide, and a replayed old response would
> resolve a new request. A uuid is unique for the life of the box.

---

## 7. Journey C: a task in a GitHub repository

Now: *"fix the failing test in acme/widgets"*. The twin calls
`start_task(title, brief, repo="acme/widgets")`. Only the differences from
Journey B are described here.

### 7.1 One repository, one project, one box, a branch per task

1. **Parse the name.** `repos.parse`
   ([repos.py:57](twin-engine/src/twin_code/repos.py#L57)) accepts
   `owner/name`, a GitHub URL or an SSH remote. It checks both halves against
   GitHub's own character rules (`_REPO`, [repos.py:26](twin-engine/src/twin_code/repos.py#L26)),
   which also keeps anything meaningful to a shell or a URL out of them.
2. **Find or create the project.** `_project` looks up the project whose
   `source` is `github:acme/widgets` (`project_from`,
   [store.py:78](twin-engine/src/twin_code/store.py#L78)), or creates one with
   `kind=repo`. The same repository always gets the same project, and so the
   same box, where its dependencies are already installed.
3. **Check out a branch.** In `open_task`, `workspace.prepare`
   ([workspace.py:99](twin-engine/src/twin_code/workspace.py#L99)) runs
   `checkout_command` ([repos.py:85](twin-engine/src/twin_code/repos.py#L85))
   in the box, with a 15-minute timeout. The command:
   - runs `git init` if there's no `.git` yet. It uses `init` and `fetch`, not
     `clone`, because the workspace volume may already hold `.cache`, and
     `clone` refuses a non-empty directory;
   - points `origin` at the **git proxy**
     (`http://git-proxy:8400/github.com/acme/widgets.git`), never at GitHub;
   - sets `http.extraHeader "Authorization: Bearer $DEEPSEEK_API_KEY"` in the
     repository's own config. The box token is what authenticates the box to
     the git proxy;
   - runs `git fetch`, then finds the remote's default branch with
     `git ls-remote --symref origin HEAD`;
   - runs `git checkout -B twin/<task id> origin/<default>`.

   Every interpolated value is `shlex.quote`d. A failure raises
   `WorkspaceError`, carrying git's last 500 characters, and the task fails
   with them.
4. **The first prompt gets repository rules.** `opening`
   ([workspace.py:76](twin-engine/src/twin_code/workspace.py#L76)) tells the
   agent:
   - which repository and branch this is;
   - to read the README, AGENTS.md and CONTRIBUTING first;
   - to run the tests and say which ones it ran;
   - to commit on this branch but not push or switch branches, because Twin
     pushes it.

### 7.2 The git proxy

`python -m twin_code.git_proxy` on port 8400. The one route is
`/github.com/{owner}/{name}.git/{rest:path}`, for `GET` and `POST`
([git_proxy.py:177](twin-engine/src/twin_code/git_proxy.py#L177)). For every
request, `Proxy.handle` ([git_proxy.py:73](twin-engine/src/twin_code/git_proxy.py#L73))
checks in this order:

1. **Token.** Take the bearer token, check its HMAC (`tokens.project_of`) and
   load the project. A bad token gets 401.
2. **Repository.** The requested `owner/name` must be the project's own.
   Another repository gets 403: a box can read and write only its own.
3. **Push check.** A push is a POST to `git-receive-pack`. `_read_push`
   ([git_proxy.py:135](twin-engine/src/twin_code/git_proxy.py#L135)):
   - refuses a compressed push, because its commands can't be read;
   - reads the body into a buffer until `pushed_refs` can parse the command
     list, up to 64 KiB;
   - refuses the push unless there's a live task **and** every ref is exactly
     `refs/heads/twin/<that task's id>` (`_allowed_branch`,
     [git_proxy.py:105](twin-engine/src/twin_code/git_proxy.py#L105));
   - otherwise forwards the buffered head and then the rest of the body
     (`_chained`).

```python
# twin-engine/src/twin_code/git_proxy.py:48-63
def pushed_refs(head: bytes) -> list[str] | None:
    """The refs a receive-pack request updates, or None until its command list has ended."""
    refs: list[str] = []
    at = 0
    while at + 4 <= len(head):
        size = int(head[at : at + 4], 16)        # 4 hex digits: this line's length
        if size == 0:                            # "0000": the command list ended
            return refs
        if at + size > len(head):                # this line isn't fully read yet
            return None
        line = head[at + 4 : at + size].split(b"\0", 1)[0].rstrip(b"\n").decode(errors="replace")
        parts = line.split(" ")                  # "<old> <new> <ref>" (capabilities after NUL)
        if len(parts) == _COMMAND_FIELDS:
            refs.append(parts[2])
        at += size
    return None
```

   *(The trailing comments are added here; they aren't in the file.)*

4. **Credential.** `GitHub.authorization`
   ([github.py:56](twin-engine/src/twin_code/github.py#L56)) asks twin-backend
   for the account's GitHub token and caches the answer for 5 minutes. A push
   with **no** credential gets a clear 403: "GitHub is not connected for this
   account…". Otherwise GitHub would answer 401, and git would try to prompt
   a terminal that nobody is watching for a username.
5. **Forward.** `_forward` ([git_proxy.py:112](twin-engine/src/twin_code/git_proxy.py#L112))
   passes on only safe headers (`content-type`, `accept`, `git-protocol`,
   `user-agent`, `content-encoding`), adds `Authorization: Basic <x-access-token:token>`
   (the form git over HTTP expects, `basic_for_git`), and streams GitHub's
   answer back. `_relayed` uses `aiter_bytes`, which decompresses, because the
   `Content-Encoding` header isn't passed on and git would otherwise receive
   raw gzip.

**The credential route, in the backend.** `POST /internal/github/credential`
([twin-git.ts:33](twin-backend/apps/backend/src/routes/twin-git.ts#L33)):

- `admitted` compares `x-twin-engine-secret` with `TWIN_ENGINE_SECRET` using
  `timingSafeEqual`, after checking the lengths match, since `timingSafeEqual`
  throws on different lengths;
- it finds the account's active GitHub connection and builds its
  `Authorization` header with the same credential strategy the MCP tools use;
- no connection gets a 404.

Only the engine's control plane (the git proxy and the code worker) knows this
secret. A box never does.

> **Why not give the box a token?** An agent that can run any command can read
> any token it holds and use it for anything that token allows. With the proxy,
> the worst a compromised box can do is push to its own task's branch.

### 7.3 The pull request

`finish_task` → `_wrap_up` → `workspace.wrap_up`:

1. Commit what's left.
2. Keep the patch.
3. Run `push_command` ([repos.py:128](twin-engine/src/twin_code/repos.py#L128)),
   which is `git push origin HEAD:refs/heads/twin/<task>`.
4. If the push is refused, `Wrapped.refused` carries git's last line. The
   report quotes it ("Not pushed: …"), so the twin can say what would let it
   through. The work stays committed in the box, and the next round tries
   again.
5. If the push succeeds, `GitHub.open_pull`
   ([github.py:75](twin-engine/src/twin_code/github.py#L75)) returns the
   branch's open PR if there is one. Otherwise it creates a **draft** PR
   against the repository's default branch, titled with the task's title, with
   the summary as its body. The PR URL is stored on the task and logged as a
   `pr` event.

### 7.4 Review comes back as the next round

While a task with a PR waits for a follow-up, `_arrives`
([code_task.py:184](twin-engine/src/twin_workflows/code_task.py#L184)) wakes
every 3 minutes (`FEEDBACK_EVERY`) and runs `pr_feedback`
([work.py:276](twin-engine/src/twin_code/work.py#L276)), which calls
`GitHub.feedback` ([github.py:101](twin-engine/src/twin_code/github.py#L101)).
That reads:

- **issue comments** on the PR, and **review comments** on its lines, updated
  after `since`;
- **failed check runs** on the PR's head commit (`failure`, `timed_out`,
  `cancelled` or `action_required`) completed after `since`.

Each item becomes a line of text, such as "Review comment from alice on
src/x.py:42: …" or "Check tests failed (url): …". The items are added to
`_inbox`, and `_next` turns them into the next round's prompt.

- **Why polling?** GitHub sends webhooks to GitHub Apps, not to OAuth Apps,
  and Twin's GitHub connection is an OAuth App. A GitHub App would remove the
  poll.
- **Why `workflow.patched("pr-feedback")`?** Task workflows that were already
  running when this code shipped have histories without these timer steps.
  During their replay `patched` returns false, so they keep their old
  behaviour and their history still matches.

### 7.5 The Changes tab

Each round's `changes` event holds the patch. `changesOf`
([lib/task-changes.ts:46](twin-frontend/lib/task-changes.ts#L46)) splits it
into files and lines, marked add, remove, context or hunk.

In `TaskChanges` ([task-changes.tsx:58](twin-frontend/components/features/code-tasks/task-changes.tsx#L58)),
each line has a comment button. The comment is turned into a message by
`reviewMessage` ([task-changes.ts:59](twin-frontend/lib/task-changes.ts#L59)):

```
Review of src/server.js, on the line `const db = new Database("chat.db")`:
use an in-memory db for tests
```

It is sent through the same steer route as any follow-up, so it becomes the
next round.

---

## 8. The frontend in depth

### 8.1 Getting task data

- **The row, polled.** `useCodeTask`
  ([entities/code-tasks/client.ts:71](twin-frontend/entities/code-tasks/client.ts#L71))
  reads `GET /api/twin/code-tasks/:id` through RTK Query. It polls every 4 s
  while the task is live (`LIVE_POLL_MS`); the board polls every 8 s
  (`BOARD_POLL_MS`).
- **The timeline, streamed.** `useCodeTaskTimeline`
  ([entities/code-tasks/stream.ts:39](twin-frontend/entities/code-tasks/stream.ts#L39))
  subscribes to `/api/twin/code-tasks/:id/stream?after=0-0`, from the **top**
  of the stream, so a page opened mid-task sees everything the stream still
  holds.
- **Types that can't drift.** The types and zod schemas in
  [entities/code-tasks/server.ts](twin-frontend/entities/code-tasks/server.ts)
  are generated from the backend's OpenAPI routes (`responseSchema(routes.listCodeTasks.backend…)`).
  A change to the contract that isn't mirrored in the page fails type-checking.

**The backend side** of the stream
([twin-code-tasks.ts:77](twin-backend/apps/backend/src/routes/twin-code-tasks.ts#L77))
works like the chat's:

1. It reads `after` from `Last-Event-ID` or `?after=`, or else the newest
   entry id, taken *before* the ownership check.
2. It checks the task is yours; another account's task gets a 404.
3. It follows `twin:task:{<id>}` and writes each entry as
   `id: <entry>\nevent: event\ndata: <json>`.
4. `announcementOf` ([code-task-stream.ts:33](twin-backend/apps/backend/src/code-task-stream.ts#L33))
   validates each entry against the `codeTaskEvent` contract. An entry that
   doesn't parse is skipped rather than breaking the stream.

### 8.2 Merging the stored timeline with the live one

```ts
// twin-frontend/lib/code-tasks.ts:260-286
export function absorb(state: LiveTimeline, event: CodeTaskEvent): LiveTimeline {
  if (event.type === "delta") {
    const kind = text(event.payload, "kind");
    const held = state.typing?.kind === kind ? state.typing.text : "";
    return { ...state, typing: { kind, text: held + text(event.payload, "text") } };
  }
  if (event.seq === undefined) return state;
  const stored = new Map(state.stored).set(event.seq, event);
  const typedOut = event.type === state.typing?.kind;
  return typedOut ? { stored } : { ...state, stored };
}

export function eventsOf(seed: readonly CodeTaskEvent[], state: LiveTimeline): readonly CodeTaskEvent[] {
  const all = new Map(seed.map((event) => [event.seq ?? -1, event]));
  for (const [seq, event] of state.stored) all.set(seq, event);
  return [...all.values()].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
}
```

- **A `delta`** adds to the "typing" text, which the page shows as the
  agent's words appearing.
- **A stored event** (one with a `seq`) goes into a map **keyed by `seq`**.
  When the stored `message` arrives, it replaces the typing text.
- **`eventsOf`** merges the server-rendered seed with the streamed events by
  `seq`. An event that is in both, because the stream replays from the top,
  appears once. The result is sorted.

### 8.3 Drawing it

- **`timelineOf`** ([lib/code-tasks.ts:190](twin-frontend/lib/code-tasks.ts#L190))
  turns events into rows:
  - a step's "running" and "done" events share an id and become **one row**;
  - `stepOf` keeps the earlier `about` when a finish event arrives without one
    (the worker-restart case from B10);
  - `approved`, `question`, `ready` and `status` become short notes.
- **`planOf`** ([:214](twin-frontend/lib/code-tasks.ts#L214)) takes the newest
  `plan` event. Each `todo_write` replaces the whole list.
- **`currentStep`** ([:221](twin-frontend/lib/code-tasks.ts#L221)) is the one
  line the card shows: the latest step, or the first line of the latest
  message.
- **`cardView`** ([card-view.ts:14](twin-frontend/components/features/code-tasks/card-view.ts#L14))
  decides what the card shows:
  - live: a spinner, the current step, and Open and Stop buttons;
  - finished: the error, if any, the diffstat (`+42 −18 · 3 files`), and
    Preview if there is one.
- **`TaskPage`** ([task-page.tsx:25](twin-frontend/components/features/code-tasks/task-page.tsx#L25)):
  - a header with the status, facts, a Stop button and the PR link;
  - the question card while it's asking;
  - tabs for Timeline, Changes, Preview (desktop or phone width) and Logs;
  - the steer box at the bottom.
- **`TaskBoard`** ([task-board.tsx:42](twin-frontend/components/features/code-tasks/task-board.tsx#L42))
  uses `boardOf` ([lib/code-tasks.ts:78](twin-frontend/lib/code-tasks.ts#L78))
  to sort tasks into Working (queued, working), Needs you (needs_input), Ready
  for review (ready) and Done (done, failed, stopped).

The logic lives in `lib/` and `*-view.ts` as pure functions, with tests under
`tests/`, following the repository's convention of keeping logic out of JSX.

### 8.4 Notifications

`TaskNotifier` ([task-notifier.tsx:14](twin-frontend/components/features/code-tasks/task-notifier.tsx#L14))
is mounted once in the app shell:

1. `useTaskArrivals` ([hooks/use-task-arrivals.ts:12](twin-frontend/hooks/use-task-arrivals.ts#L12))
   watches the polled task list. It ignores the first read, which is what was
   already true, not news. After that, `arrivals`
   ([lib/code-tasks.ts:233](twin-frontend/lib/code-tasks.ts#L233)) reports
   each task whose status just changed to `needs_input`, `ready` or `failed`.
2. Each arrival shows an in-app toast with an Open button.
3. It also calls `notifyOs` ([notify.ts:14](twin-frontend/components/features/code-tasks/notify.ts#L14)),
   which shows a system notification only if you allowed notifications **and**
   the tab is hidden. The notification is tagged with the task id, so repeats
   replace each other, and clicking it focuses the tab and opens the task.

---

## 9. The twin's harness

The harness is everything around the model call. It is wired together in
[twin_deep.py:130-285](twin-engine/src/twin_agent/twin_deep.py#L130).

### 9.1 Resilience

```python
# twin-engine/src/twin_agent/resilience.py:87-102 (abridged)
    return [
        *([ModelFallbackMiddleware(*chain)] if chain else []),
        ModelRetryMiddleware(max_retries=MODEL_RETRIES, retry_on=_transient, on_failure="error"),
        *([ToolRetryMiddleware(max_retries=TOOL_RETRIES, tools=reads)] if reads else []),
        ContextEditingMiddleware(edits=[ClearToolUsesEdit(
            trigger=CLEAR_AT_TOKENS, clear_at_least=CLEAR_AT_LEAST, keep=KEEP,
            exclude_tools=NEVER_CLEARED,
            placeholder="[cleared to save context; call the tool again if you need it]",
        )]),
    ]
```

Middleware listed first wraps everything after it:

1. **`ModelFallbackMiddleware`** is outermost. When a model call fails *after
   its retries*, it tries the next model in the chain: `TWIN_FALLBACK_MODELS`,
   or by default DeepSeek V4 Pro then Gemini flash-lite (a strong model, then
   a cheap one on a different provider). `fallbacks`
   ([resilience.py:71](twin-engine/src/twin_agent/resilience.py#L71)) removes
   the current model from the chain.
2. **`ModelRetryMiddleware`** retries transient errors twice. `_transient`
   ([resilience.py:61](twin-engine/src/twin_agent/resilience.py#L61))
   excludes `StreamCutShortError`: `CutShort` has already retried a stream that
   ended early, and a provider that keeps doing that should be left for the
   fallback, not retried again.
3. **`ToolRetryMiddleware`** applies to **read tools only** (those in
   `READS`). Retrying a write could post twice.
4. **`ContextEditingMiddleware`**: once the context passes 90k tokens, old
   tool results are replaced with a placeholder, at least 20k tokens at a
   time, always keeping the last 6. `write_todos` and `dossier_read` are never
   cleared, because the twin reads both back later in the turn.

> **Why clear in 20k batches?** Clearing changes the prompt prefix, which
> throws away the provider's prompt cache. One big clear now and then keeps the
> cache valid most of the time, where a small clear on every call would never
> let it be reused.

The chain applies only to real OpenRouter models: a scripted test model has no
provider to lose.

### 9.2 Subagents

`subagents=[researcher(...), spec(DRAFTER, ...), spec(REVIEWER, ...)]`
([twin_deep.py:239](twin-engine/src/twin_agent/twin_deep.py#L239)):

- **researcher**: reads connectors, memory and the web, on the cheaper
  `TWIN_SUBAGENT_MODEL` (default `deepseek/deepseek-v4-flash-0731`,
  [roster.py:40](twin-engine/src/twin_agent/roster.py#L40)).
- **drafter** ([roster.py:43](twin-engine/src/twin_agent/roster.py#L43)):
  - reads how you write (`memory_how_they_work`, `dossier_read`);
  - drafts a message in your voice;
  - returns the draft and one line on anything it was unsure of.

  It **has no send tools**.
- **reviewer** ([roster.py:58](twin-engine/src/twin_agent/roster.py#L58)): a
  "careful senior engineer who did not do the work". It reads a finished task
  with `get_task` and checks each thing asked against the steps and the patch,
  trusting the steps over the summary. It answers `done` or `not done` plus
  exactly what is missing.

`spec` ([roster.py:106](twin-engine/src/twin_agent/roster.py#L106)) gives each
role only the tools its `allowed` list names, all of them reads. **Many
readers, one writer**: only the twin itself acts.

### 9.3 Skills

- **What a skill is.** A SKILL.md file: frontmatter with `name` and
  `description`, then a markdown body.
- **Where skills come from.** `skill_store.listed`
  ([skill_store.py:75](twin-engine/src/twin_relay/skill_store.py#L75)) merges
  three sources. A later one overrides an earlier one with the same name:
  1. the **built-ins** in [twin_agent/skillbook/](twin-engine/src/twin_agent/skillbook)
     (`status-update`, `meeting-prep`, `pr-review`);
  2. the **company's** rows (`twin_id IS NULL`);
  3. **your** rows.

  Rows are written whole with an upsert (`save`,
  [:94](twin-engine/src/twin_relay/skill_store.py#L94)). Two partial unique
  indexes cover the two scopes: one per company per name, and one per twin per
  name.
- **The twin sees one line per skill.** `SkillShelf`
  ([skills.py:72](twin-engine/src/twin_agent/skills.py#L72)) fetches the list
  once per run from `GET /internal/skills` and appends a "## Skills" block to
  the system message of every model call:
  `` - `pr-review`: how to review a PR the way they do ``.

  The body is read only when needed, with `skill_read`. A hundred skills cost
  a hundred lines of context, not a hundred playbooks.
- **The twin can write skills.** `skill_save` records a procedure it has
  worked out, as yours or, with `shared=true`, as your company's.
- **dsh gets the same skills.** `install_skills`
  ([workspace.py:122](twin-engine/src/twin_code/workspace.py#L122)) writes
  every skill to `$DSH_HOME/skills/<name>/SKILL.md` in the box on each open,
  where dsh reads skills natively. The files are sent as **one base64
  argument** to Python inside the box, so no skill text is ever parsed by a
  shell. The folder is rewritten whole each time, so a deleted skill
  disappears from the box too.

### 9.4 Idempotency keys on connector writes

When a turn is resumed after a crash (A9), the tool call that was in flight
runs again, with the **same** tool-call id the model issued. `IdempotencyKeys`
([mcp.py:45](twin-engine/src/agent_runtime/tools/mcp.py#L45)) is an MCP
client interceptor:

- `learn` marks a tool as a write unless its server marks it `readOnlyHint`;
- for writes, it adds `Idempotency-Key: <run id>:<tool call id>`
  (`key_for`, [mcp.py:76](twin-engine/src/agent_runtime/tools/mcp.py#L76)).

twin-backend's MCP route honours the key (`offeredKey`,
[mcp.ts:256](twin-backend/apps/backend/src/routes/mcp.ts#L256)). It accepts
only keys matching `^[\w:.-]{8,200}$`, and falls back to a random one
otherwise. A repeated key gets the first call's result back instead of posting
again.

### 9.5 The gates

`interrupt_on` ([gates.py:280](twin-engine/src/twin_agent/gates.py#L280))
lists the tools that stop for approval (`APPROVAL_GATES`,
[gates.py:67](twin-engine/src/twin_agent/gates.py#L67), plus the file tools
and the shell when there is a workspace). Every gate uses the same predicate,
`_asking` ([gates.py:199](twin-engine/src/twin_agent/gates.py#L199)):

```python
# twin-engine/src/twin_agent/gates.py:223-225
    if authorship.refusal(request.tool_call, request.state["messages"]):
        return False
    return not auto_mode.unattended(request)
```

- **Don't ask about a call authorship will strike.** You'd be asked to
  approve something that can't run, which teaches people to stop reading
  approvals.
- **Ask the same question authorship acts on.** deepagents raises the approval
  interrupt *before* `Authorship` runs, so both must reach the same answer from
  the call and the turn's messages. `refusal` is a pure function of those two,
  and it doesn't depend on whether the run can start a task: only the route
  named in the message does.
- **Why that matters.** An older version refused nothing on a run with no route
  for code, while the gate still skipped the calls `refusal` named, so a source
  write or a build went through **with no approval at all**. Making the limit
  independent of the route closed that.
- **Auto mode.** `auto_mode.unattended` is read at the moment of the call, so
  flipping auto mode on during a turn affects the very next call.
- **No `claude-code` gate.** The twin holds none of that connector's tools, and
  a gate for a tool it can't call would ask a person to approve nothing.

---

## 10. Operations: evals, metrics, limits

### 10.1 `make eval`

[twin_evals/](twin-engine/src/twin_evals) drives the engine's real routes as a
fixed eval account. Every case names the real failure it guards against
([cases.py](twin-engine/src/twin_evals/cases.py)).

- **Turn cases** ([cases.py:54](twin-engine/src/twin_evals/cases.py#L54)) are
  judged by which tools were called and not called:

| Case | Prompt | Must | Must not |
| --- | --- | --- | --- |
| `snippet-in-the-reply` | "Write me a Python function that returns the nth Fibonacci number." | say `def ` | start a task or write files |
| `code-goes-to-a-task` | "Build me a tiny web page that shows a random quote…" | call `start_task` | write code itself |
| `no-tool-says-so` | "Book me a flight to Lahore next Friday morning." | — | start a task or write files |

- **Job cases** ([cases.py:77](twin-engine/src/twin_evals/cases.py#L77)) are
  judged by the result:

| Case | Checks |
| --- | --- |
| `greenfield-vite-app` | ends `ready`, serves a preview, costs under $0.30 |
| `repo-one-line-change` | in `python-humanize/humanize`, touches exactly `README.md`, under $0.10 |
| `panel-follow-up-is-a-request` | after a follow-up sent the panel's way, no report turn calls `stop_task` |

The runner ([__main__.py](twin-engine/src/twin_evals/__main__.py)) has two
subtleties:

- **`turns_settled`** treats a 404 as "not yet": the thread row doesn't exist
  until the first turn is projected.
- **`task_settled(prompted=…)`** waits for a `ready` event *after* the
  follow-up's `prompt` event (`_after`, [:91](twin-engine/src/twin_evals/__main__.py#L91)).
  A ready task stays `ready` until its queued follow-up is picked up, so
  checking the status alone would judge the previous round.

It writes `evals-report.json`, prints one line per case, and exits non-zero on
any failure. The first run passed 6 of 6 for about $0.20.

### 10.2 `/metrics`

`GET /metrics` on the engine, with the relay secret as bearer
([metrics.py:100](twin-engine/src/twin_relay/metrics.py#L100)), returns
Prometheus text read straight from Postgres, so any replica can answer:

- `twin_turns_24h{status}` and `twin_turn_spend_usd_24h`;
- `twin_tasks{status}` and `twin_task_spend_usd`;
- `twin_boxes{state}`.

### 10.3 Limits and settings

All code settings are read once, in [twin_code/settings.py](twin-engine/src/twin_code/settings.py):

| Variable | Default | Enforced at |
| --- | --- | --- |
| `TWIN_CODE_MAX_COST_USD` | 2.0 | LLM proxy, 402 |
| `TWIN_CODE_MAX_LIVE_TASKS` | 3 | `POST /internal/tasks`, 429 |
| `TWIN_BOX_RUNTIME` | runc (empty) | box creation; `runsc` for gVisor |
| `TWIN_BOX_IMAGE` | `twin-box:dev` | box creation (`make sandbox-image` builds it) |
| `TWIN_PREVIEW_URL` | `http://{box}.{port}.preview.localhost:47620` | `finish_task` |
| `TWIN_FALLBACK_MODELS` | V4 Pro, Gemini flash-lite | the twin's fallback chain |
| `TWIN_SUBAGENT_MODEL` | V4 flash | the researcher |

The runbook is [twin-engine/docs/runbook.md](twin-engine/docs/runbook.md).

---

## 11. Claude Code (M6): the connector stays, the twin stops coding through it

The original plan was to delete the Claude Code integration once the dsh path
reached parity. On 2026-09-24 that was narrowed:

- **The `claude-code` connector stays.** twin-connectors' provider,
  twin-backend's handling of it and `twin-engine/claude-agent/` are unchanged,
  because the product still integrates with Claude Code.
- **The twin no longer codes through it.** It holds none of the connector's
  tools, so it can't spawn, prompt, answer or wait on a session. Its prompt and
  `authorship.py` name only two routes: its own small file, and a coding task.
- **Gone from the engine with that change:** `await_claude_session`
  (`awaiting.py`), `SpawnDirectory` (`spawning.py`), the spawn approval gate,
  the Claude section of the prompt, and the `claude-code-delegation` skill.
  The relay's session routes (`/internal/sessions/…/steps`, `/internal/notify`)
  and the `EXTERNAL` branch of `_settle` (4.1) remain for twin-backend, which
  still sends them; with no twin waiting on a session, they find nothing to
  resume.

The `feat/m6-remove-claude-code` branches, which delete the whole integration
in all four repositories, are kept for reference and are not to be merged as
they stand. The spec records the change at the end of
[its section 9](twin-engine/docs/superpowers/specs/2026-09-23-production-runtime-design.md).

---

## 12. What happens when something dies

| What dies | What happens | Why nothing is lost |
| --- | --- | --- |
| An `engine` replica | The backend's next call reaches another replica | The API holds no state. The sweep's advisory lock moves to another replica within 10 s |
| An `engine-worker` mid-turn | Heartbeats stop. After 30 s Temporal retries `run_turn` on another worker, which finds the run RUNNING and resumes it from the checkpoint | The same `turn_id`, the checkpoint, and idempotency keys on writes. The step in flight runs again (at least once) |
| An `engine-worker` on deploy (SIGTERM) | 30 s to finish. Then its turns are cancelled *as a shutdown*, and the row stays RUNNING | `_beating` tells a shutdown from a stop, and the retry resumes |
| A `code-worker` mid-prompt | dsh keeps working under acpd. After 60 s Temporal retries `prompt_task`, which reads the last heartbeat's `Progress`, reattaches from the committed line, and **doesn't** re-send the prompt | acpd's log, `Progress`, and the `source` key on events |
| A browser tab, or its network | `EventSource` reconnects with `Last-Event-ID`, and the backend resumes the stream from that entry | Redis Stream ids |
| Redis | Live views stall. Records are intact | Postgres is the record. Pages reload from it |
| Temporal | Commands can't be delivered, so the engine returns errors. Running activities finish but can't report until Temporal is back | Temporal's history. Workflows carry on where they were |
| The model provider (twin) | Retries, then the fallback model | `ModelFallbackMiddleware` |
| The model provider (dsh) | The prompt ends with an error, and the task fails with it | `_ended` treats an error as a failure, with the reason |
| A box, removed by hand | The next open makes a new container on the same volumes | The volumes are named after the project |

---

## 13. Sharp edges found while writing this

These came from reading the code closely for this document. None has been
reproduced yet; each is worth a test.

1. **A failed CI check can repeat every 3 minutes.** In `GitHub.feedback`
   ([github.py:118-119](twin-engine/src/twin_code/github.py#L118)), `until` only
   advances to the newest **comment** time. Failed checks are selected by
   `completed_at > since` on the PR's current head commit. If a round ends
   without a new commit on the branch (the agent changed nothing, or the push
   was refused), the same failed check is still newer than `since` on the next
   poll. It is then sent as a follow-up again, every 3 minutes, until the spend
   ceiling stops it. A fix: advance `until` to the newest check completion too,
   or remember which check-run ids were sent.
2. **A dsh crash mid-prompt may hang the round.** If dsh itself dies, acpd
   exits and the box restarts with a new dsh. The attach stream ends, so
   `prompt_task` fails and is retried. The retry's heartbeat still has the old
   `prompt_id`, so it reattaches and waits for a response the new dsh will
   never send. It keeps heartbeating, so nothing times out until the 3-hour
   `prompt_task` limit, with up to 6 attempts. A fix: have `prompt_task` check
   `acpd status`'s `pid` against the one recorded when the prompt was sent, and
   re-prompt (or fail clearly) when it has changed.

---

## 14. Glossary

| Term | Meaning |
| --- | --- |
| **acpd** | Twin's supervisor inside each box. It holds dsh's stdio, numbers and logs every line, and lets workers attach from line N |
| **ACP** | Agent Client Protocol: JSON-RPC for driving a coding agent |
| **Activity** | A Temporal step that may do I/O. It is retried, has timeouts, and heartbeats |
| **Adopt** | Starting a thread's workflow parked on a run it didn't park |
| **Box** | A project's container, `twinbox-<hex>` |
| **Box token** | `<project id>.<HMAC>`. The box's only credential, accepted by the LLM and git proxies |
| **Checkpoint** | LangGraph's saved state after each step, in Postgres |
| **Committed line** | The last acpd line whose events are all stored, which is what the heartbeat records |
| **dsh** | DeepSeek Harness, the coding agent in the box |
| **Event-started turn** | A twin turn started by a task's report rather than by you (`origin = task`) |
| **Frame** | A small live event from a turn (token, tool start, tool end), streamed to the chat |
| **Gate** | An approval the twin must get before an irreversible tool call |
| **Heartbeat** | An activity's "still alive" signal to Temporal, optionally carrying progress |
| **Live task** | A task in `queued`, `working` or `needs_input`. At most one per project |
| **Projection** | The chat tables the page draws, built from runs and checkpoints |
| **Progress** | `(seq, prompt_id, pending_id)`: how far a task's stream is read, and what is in flight |
| **Signal** | A one-way message into a running Temporal workflow |
| **Source key** | `<line>:<index>` on a task event. It makes re-writing the same event a no-op |
| **Tenant** | Who a turn acts as: account, company, connector key and filesystem root |
| **Turn** | One round of the twin thinking and acting. One `runs` row |
| **Workflow** | A durable Temporal function. `ThreadWorkflow` per chat, `CodeTaskWorkflow` per task |
