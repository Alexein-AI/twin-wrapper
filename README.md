# twin

Five repositories, one system, one command.

```bash
./setup.sh            # once, after cloning
docker compose up -d  # every time after that
```

Then open <http://localhost:4000>.

## What runs

| Service | Where | What it is |
| --- | --- | --- |
| `frontend` | <http://localhost:4000> | the web client. **Start here.** |
| `backend` | <http://localhost:8080> | API, ingest worker, and the webhook receiver |
| `connectors` | `connectors:8090` | every provider's code. No host port, by design |
| `engine` | <http://127.0.0.1:8000> | the agent runtime. Unauthenticated dev harness, loopback only |
| `memory-api` | <http://127.0.0.1:8200> | retrieval. Loopback only |
| `memory-consumer` | — | drains `twin:events` into the memory store |
| `postgres` | `localhost:5500` | one server, one database per repo |
| `redis` | `localhost:6500` | queues, rate limits, and the event list |

Plus one process that is **not** a container and cannot be: the Claude Code
agent. It drives tmux and reads `~/.claude` on this machine, so `setup.sh`
installs it as a launch agent and it starts at login.

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

The root `.env` is deliberately small: only what compose needs *before* a
container exists — a volume path, a published port, a build argument. See
[.env.example](.env.example). `./setup.sh` writes it.

Values that cannot be copied between machines — the relay secret, the shared
`CONNECTORS_SECRET`, the agent's pairing token — are minted by `setup.sh`,
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
seven containers:

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
./setup.sh --pair                         # the agent's 2-minute pairing window
```

## Two steps no script can do

1. **Sign in** at <http://localhost:4000>. Identity is Clerk's (ADR 37), so this
   is a browser sign-in with no terminal equivalent: the connect route and
   minting a `twk_` key are both behind `requireViewer`.
2. **Pair Claude Code.** Open <http://localhost:4000/connections>, run
   `./setup.sh --pair`, and press Connect within two minutes. The agent mints
   its own token during that claim; nothing is pasted.

## Ports

`twin-engine/docs/ports.md` is the register, and it still is — check it before
binding a host port, and add the row in the same commit.
