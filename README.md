# twin

Five repositories, one system, one command.

```bash
./setup.sh            # once, after cloning
docker compose up -d  # every time after that
```

Then open <http://localhost:4000>. On a new machine, start with
[Setting up from scratch](#setting-up-from-scratch).

## Setting up from scratch

**1. Tools.** Docker Desktop, running: every service is a container and carries
its own runtime. The Claude Code agent is the one thing on the host, and it
needs tmux at `/opt/homebrew/bin/tmux` (`brew install tmux`; it looks nowhere
else) and the `claude` CLI, logged in. `./setup.sh --no-agent` skips the agent
and both. Node 22+ and pnpm are only for `make check` on the host.

**2. The five repositories go inside this one.** They are separate clones, not
submodules, and `.gitignore` keeps them out of this repo:

```bash
git clone https://github.com/Alexein-AI/twin-wrapper.git && cd twin-wrapper
for r in backend connectors engine frontend memory; do
  git clone https://github.com/Alexein-AI/twin-$r.git
done
for r in backend connectors engine frontend; do git -C twin-$r checkout dev; done
```

Work lands on `dev` in four of them. twin-memory has only `main`, so the
"not on dev" warning `setup.sh` gives for it is expected.

**3. `./setup.sh`, twice.** On a fresh clone it copies each repo's
`.env.example` into place, then stops at the values only a person can supply.
Set them all, then run it again:

| File | Values |
| --- | --- |
| `twin-backend/.env` | `CLERK_SECRET_KEY`, `CLERK_JWT_KEY`, `TWIN_ROOT` |
| `twin-frontend/.env.local` | `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY`, `TWIN_PUBLIC_URL` |
| `twin-engine/.env` | `OPENROUTER_KEY`, `TWIN_ROOT`, `TWIN_SANDBOX_ACCOUNTS=*` |

- The Clerk keys are one Clerk application's, so `CLERK_SECRET_KEY` is the
  same string in both files.
- `TWIN_ROOT` is an absolute path, and the same string in both files.
- `TWIN_PUBLIC_URL` must share an origin with the backend's `FRONTEND_URL`,
  or Connect is refused. `http://localhost:4000` for both.

The second run makes everything else: the per-machine secrets, the copies of
the model key, the root `.env`, the three sandbox images, and the agent's
launch agent. It is safe to re-run,
and `./setup.sh --check` reports without writing anything.

**4. Start it.** `docker compose up -d`, open <http://localhost:4000>, and do
the [two steps no script can do](#two-steps-no-script-can-do).

## What runs

| Service | Where | What it is |
| --- | --- | --- |
| `frontend` | <http://localhost:4000> | the web client. **Start here.** |
| `backend` | <http://localhost:8080> | API, ingest worker, and the webhook receiver |
| `connectors` | `connectors:8090` | every provider's code. No host port, by design |
| `engine` | <http://127.0.0.1:8000> | the engine's API, `twin_relay`. Every route needs the relay secret; it runs no turns itself. Loopback only |
| `engine-worker` | — | runs every turn, off Temporal. `--scale engine-worker=N` for more |
| `temporal` | <http://127.0.0.1:8233> | durable execution: a chat is a workflow, a turn an activity. The UI is loopback only |
| `code-worker` | — | runs coding tasks, each in a box of its own. Reaches no Docker |
| `sandbox-broker` | `sandbox-broker:8766` | the one process holding the Docker socket, so the only one that makes containers |
| `llm-proxy` | `llm-proxy:8300` | a box's only route to the model, holding the one key |
| `git-proxy` | `git-proxy:8400` | a repo box's `origin`: its own repository and branch only |
| `preview` | <http://127.0.0.1:47620> | what a box serves, at `<box>.<port>.preview.localhost` |
| `memory-api` | <http://127.0.0.1:8200> | retrieval. Loopback only |
| `memory-consumer` | — | drains `twin:events` into the memory store |
| `postgres` | `127.0.0.1:5500` | one server, one database per repo |
| `redis` | `127.0.0.1:6500` | queues, rate limits, and the event list |
| `langfuse-*` | <http://127.0.0.1:3000> | the twin's traces, with its own Postgres, Redis, ClickHouse and MinIO on a network of their own |
| `tunnel`, `tunnel-named` | — | a public url for inbound webhooks. Behind profiles of the same names, so off by default |

Plus what the broker starts on demand: one container per account, holding its
workspace; one box per project a coding task works in, on that account's
network; and one egress proxy that every one of them goes out through. One thing
runs outside Docker, as on `main`:
the Claude Code agent (`twin-engine/claude-agent/`), a separate ingestion
service on this machine that reads `~/.claude` here and pushes what its
sessions did to the backend. `setup.sh` installs it; `--no-agent` skips it.

## How an event becomes a memory

The path worth knowing, because it crosses four of the five repositories:

```
provider  ──POST /webhooks/:provider──▶  backend
                                          │  asks connectors to route and verify it
                                          ├─▶ connectors  (stateless: no database, no queue)
                                          │
                                          │  queues an ingest job, normalises, stores
                                          ├─▶ postgres/twin_backend
                                          │
                                          │  the outbox announces it; the sink appends
                                          └─▶ redis  RPUSH twin:events
                                                       │
                                  memory-consumer  ◀───┘  LMOVE … LEFT RIGHT
                                          │
                                          └─▶ the store, a directory of files + a SQLite index

and back the other way, before every turn:

  backend  ──POST /retrieval/text──▶  memory-api  ──▶ the same store
```

Two things about that diagram are recent. The sink existed in `twin-backend`
but nothing ever set `SINK_REDIS_URL`, so it was never built and nothing was
ever remembered; compose sets it now. And the two sides disagreed about the
message shape — `twin-memory`'s consumer reads both shapes today, the flat one
`producers/` replays a corpus in and the `{delivery, event}` one the backend
sends.

## Configuration

Each repository keeps its own `.env`. That is what `make run` and `pnpm dev`
read on the host, and `docker-compose.yml` loads the same files with `env_file`,
so there is one copy of each key rather than two.

The root `.env` is deliberately small: only what compose interpolates itself —
a volume path, a published port, a build argument, a subnet, and the secrets of
the services that load no repository's `.env`: the sandbox broker and the two
box proxies. [.env.example](.env.example) lists six required values, then every
other setting compose reads, commented out at its default. `./setup.sh` writes
it.

One key is in two places on purpose. `llm-proxy` gets `OPENROUTER_KEY` from the
root `.env` rather than `twin-engine/.env`, because a coding box can open a
socket to it and `env_file` would hand it that whole file. `./setup.sh` copies
it from `twin-engine/.env` on every run, so change it there and rerun.
twin-memory's copy, `OPENROUTER_API_KEY`, is filled from the same key only while
it is empty, since memory may have a key of its own. A rotated key has to be
changed there by hand, and `setup.sh` warns while the two differ.

Values that cannot be copied between machines — the relay secret, the shared
`CONNECTORS_SECRET`, the sandbox broker's two tokens, the box proxies' bearer —
are minted by `setup.sh`,
because a copied secret is not a missing one. It is a wrong one, and every
engine route answers 401 without saying why.

## One server, three databases

Every repository used to name its database `twin`, which was fine while each ran
a Postgres of its own. They share one now, so the names moved:
`twin_backend`, `twin_engine`, `twin_memory`, created by
[docker/postgres/initdb.d/10-databases.sql](docker/postgres/initdb.d/10-databases.sql).

That file runs **only on an empty data directory** — the postgres image's rule,
not ours. Adding a database later means running the `CREATE DATABASE` by hand,
or `docker compose down -v`, which costs the data.

## Working on one repository

Each repo keeps a `docker-compose.yml` of its own holding just its services,
joined to the shared network. Use it to rebuild one thing without recreating
the whole stack:

```bash
cd twin-memory
docker compose up -d --build       # the root stack must be up first
docker compose logs -f consumer
```

They declare the network as `external`, so compose says so plainly when the root
stack is not up: `network twin_default not found`.

## Everyday commands

```bash
docker compose up -d                      # the whole thing
docker compose logs -f backend            # or any service above
docker compose watch                      # rebuild-on-edit for backend and connectors
docker compose down                       # stop, keep the data
docker compose down -v                    # stop and drop the databases and the store
docker compose --profile tunnel-named up -d   # a public url for inbound webhooks

./setup.sh --check                        # what is missing, changing nothing
```

## Two steps no script can do

1. **Sign in** at <http://localhost:4000>. Identity is Clerk's (ADR 37), so this
   is a browser sign-in with no terminal equivalent: the connect route and
   minting a `twk_` key are both behind `requireViewer`.
2. **Pair Claude Code.** On <http://localhost:4000/connections> press Connect on
   Claude Code and give it the agent's pairing password - `make agent-password`
   in twin-engine says whether one is set, and
   `TWIN_AGENT_PAIR_PASSWORD=... make agent-setup` there sets it.

## Ports

`twin-engine/docs/ports.md` is the register, and it still is — check it before
binding a host port, and add the row in the same commit.
