# Design: EmergenceSystem Network Transition — em_disco → em_pop

**Date:** 2026-05-28  
**Author:** Steve Roques  
**Status:** Approved  

---

## Problem statement

em_disco is a single point of failure. Every agent and every query goes through it. It cannot scale horizontally, does not route semantically, and its removal would break everything at once.

The goal is to migrate to a fully decentralised peer-to-peer network based on Population Protocols (em_pop), where:

- Agents discover each other without any coordinator.
- Emquest dispatches queries directly to the most semantically relevant agents.
- em_disco "retrogrades" into an ordinary em_filter node that serves as a stable bootstrap seed — it loses its central bus role but keeps its address in the config unchanged.
- The migration happens in three phases with no flag-day cutover.

---

## Architecture overview

### Today (Phase 1 — partially done)

```
[Agent A] ──ws──┐
[Agent B] ──ws──┼──► em_disco (registry + bus + bootstrap)  ◄──HTTP── Emquest
[Agent C] ──ws──┘
```

em_disco does three jobs in one process: registry, query bus, and network entry point.  
em_pop nodes are already embedded in agents (Phase 1 done), but em_disco is still the query channel.

### Phase 2 — parallel routing

```
[Agent A]  em_pop ◄──gossip──► em_pop [Agent B]
    │                                       │
  query_port HTTP                     query_port HTTP
    ▲                                       ▲
    └──────────── Emquest (em_pop node) ────┘
                     │
               also still queries em_disco
               (fallback during transition)
```

Emquest gains its own em_pop node and begins routing queries directly to agents via their `query_port`. em_disco is still queried in parallel as a safety net.

### Phase 3 — disco retrogrades (end state)

```
  [em_disco-filter]   [Agent A]   [Agent B]   [Agent C]
        │                 │            │            │
        └─────────────────┴────────────┴────────────┘
                     em_pop gossip network

  Emquest ──em_pop──► peers_for(Vec, K) ──HTTP──► top-K agents
```

em_disco is rewritten as a plain em_filter agent. Its only special property is having a stable address and a large `max_peers`. No WebSocket bus, no central registry. Emquest dispatches without it.

---

## Component changes

| Component | Phase 1 (now) | Phase 2 | Phase 3 |
|---|---|---|---|
| **em_filter** | WS→disco + em_pop node | + query_port HTTP endpoint | remove WS→disco |
| **em_disco** | central bus | seed node + bus (parallel) | em_filter with large max_peers, no bus |
| **Emquest** | dispatch via disco only | dispatch via em_pop + disco | dispatch via em_pop only |
| **em_pop payload** | id, host, port, vector, peers | + query_port field | same |
| **emergence.conf** | `[em_disco] nodes` = bus address | unchanged | unchanged (same key, new meaning: seed address) |

### What does not change for operators

The `[em_disco] nodes` key in `emergence.conf` keeps the same syntax. Its meaning shifts from "WebSocket bus to connect to" to "em_pop seed node to bootstrap from". No config migration needed.

---

## Query flow in Phase 3 (end state)

```
User types: "Python RSS news"
      │
      ▼
Emquest: POST /query received
      │
      ├─ queen:expand("Python RSS news")
      │    → [<<"rss">>, <<"python">>, <<"news">>]
      │
      ├─ em_filter_vec:from_capabilities([<<"rss">>, <<"python">>, <<"news">>])
      │    → 64-dim f32 unit-norm vector
      │
      ├─ em_pop_node:peers_for(EmquestPopPid, Vec, 10)
      │    → kvex SIMD search over ~5 000 known peers  (<1 ms)
      │    → [{Agent_RSS @ port 9201, score 0.92},
      │       {Agent_Web @ port 9301, score 0.71}, ...]
      │
      ├─ [spawn per agent] HTTP POST /agent/query → handler:handle/2
      │    → each agent runs its own logic, returns JSON results
      │
      └─ collect results + SSE stream → browser
```

No em_disco in the query path. Latency = kvex search + parallel HTTP round-trips.

---

## New piece: agent query HTTP endpoint (`query_port`)

Each em_filter agent that sets `query_port => N` in its Config starts a second Cowboy listener:

```
POST /agent/query
Body:     {"query": "python news", "id": "abc123", "capabilities": ["rss"]}
Response: {"results": [...]}
```

The handler calls `handler_module:handle(QueryBinary, Memory)` directly, exactly as the WebSocket path does today.

The `query_port` value is embedded in the em_pop gossip payload as a new field. When Emquest calls `peers_for/3`, each returned peer map includes `query_port`, so Emquest has everything it needs: host, query port, and similarity score.

Agents without `query_port` are not reachable via direct HTTP. During Phase 2, Emquest still queries em_disco for these agents (backward compatibility).

---

## em_pop payload extension

Current payload fields: `id`, `host`, `port` (gossip), `vector`, `peers`.

New field added: `query_port` (integer, optional — `null` if not configured).

```json
{
  "id":         "<base64 16 bytes>",
  "host":       "agent-a.mynet.com",
  "port":       9200,
  "query_port": 9201,
  "vector":     "<base64 f32×64>",
  "peers":      [...]
}
```

Nodes that do not expose a query endpoint send `"query_port": null`. Backward-compatible with existing em_pop nodes that predate this field.

---

## em_disco-filter (Phase 3)

em_disco is rewritten as a standard em_filter application with:

- **em_pop node** with `max_peers = 10 000` (knows most of the network).
- **query_port** exposed so it can still answer queries if contacted directly.
- **No WebSocket bus** — the `em_disco_handlers` WebSocket handler is removed.
- **No central registry ETS** — peer knowledge lives in em_pop's peer table.
- **Stable address** — its hostname and port remain the same; agents that read `[em_disco] nodes` from `emergence.conf` bootstrap their em_pop from it seamlessly.

Its capabilities vector: `[<<"bootstrap">>, <<"registry">>, <<"search">>]`.

---

## Bootstrap mechanism

### Phase 2

em_disco runs two servers simultaneously during Phase 2:
- **WebSocket bus** on its existing port (e.g., 8080) — unchanged, agents connect as before.
- **em_pop gossip HTTP** on a new port declared in config (e.g., 9000).

A new key is added to `emergence.conf` for the em_pop seed port:

```ini
[em_disco]
nodes     = disco.mynetwork.com:8080   ; WebSocket bus — unchanged
pop_port  = 9000                       ; em_pop gossip seed port — new
```

Bootstrap sequence for a new agent:

1. Agent reads `[em_disco] nodes` + `pop_port` from `emergence.conf`.
2. Calls `em_pop_node:add_peer(PopPid, Host, PopPort)` to contact the seed.
3. The gossip exchange returns the seed's peer list → transitive discovery begins.
4. After O(N log N) pairwise gossip interactions, the agent knows a representative sample of the network.

During Phase 2 the seed node is still running the old em_disco code (the WebSocket bus still works). Agents use both channels simultaneously.

### Phase 3

Same bootstrap, same `pop_port` config key. The seed node now runs em_filter instead of em_disco. The `nodes` key (WebSocket address) becomes unused and can be removed at the operator's convenience. From the bootstrapping agent's perspective nothing changes: it makes an HTTP gossip POST to `pop_port` and receives a peer list in return.

---

## Emquest changes

### Phase 2 additions

- Start one `em_pop_node` at application boot (`max_peers = 5 000`).
- Seed from `[em_disco] nodes` in `emergence.conf` (same config, no change).
- In `emquest_handler`, after the existing disco query, also run a parallel em_pop dispatch. Merge results before deduplication.
- New helper: `emquest_pop.erl` — owns the Emquest em_pop node lifecycle.

### Phase 3 changes

- Remove the `fetch_from_disco/2` call from `emquest_handler`.
- Remove `queen:disco_nodes/0` call (or keep it only for legacy nodes without `query_port`).
- `run_pipeline/2` becomes: expand → vec → `peers_for/3` → parallel HTTP → collect → SSE.

---

## Scalability note

With the flat PP approach and `max_peers = 5 000` on Emquest:

- kvex SIMD search over 5 000 peers: sub-millisecond on any modern CPU.
- PP convergence with N agents: O(N log N) gossip rounds. At N=10 000 agents, the network fully converges in ~130 000 pairwise exchanges — happening continuously in the background.
- The trust model naturally elevates active, reliable agents in Emquest's peer table. Stale or dead agents are evicted automatically.
- If the network grows beyond ~50 000 active agents, the architecture can extend to super-nodes (hierarchical PP) without changing the em_filter or Emquest API — only `max_peers` configurations and gossip topology change.

---

## Migration path summary

| Step | What changes | Backward compatible? |
|---|---|---|
| Phase 1 | em_pop embedded in em_filter agents | ✅ Yes — disco still works |
| Phase 2a | Add `query_port` to em_filter + em_pop payload | ✅ Yes — field is optional |
| Phase 2b | Emquest gets em_pop node, dispatches in parallel | ✅ Yes — disco still queried |
| Phase 2c | Flip Emquest to em_pop-primary, disco-fallback | ✅ Yes — fallback kept |
| Phase 3a | Rewrite em_disco as em_filter | ✅ Yes — same address, same em_pop port |
| Phase 3b | Remove WS code from em_filter_server | ⚠️ Breaking for old disco-only agents |
| Phase 3c | Remove disco fallback from Emquest | ⚠️ Requires all agents to have query_port |

Phase 3b and 3c can be delayed indefinitely. The network is functional and semantically routed after Phase 2.

---

## Open questions (deferred)

- **Query vector for Emquest**: `queen:expand` produces keywords; `em_filter_vec` hashes them. This is approximate. A future improvement could use the `emb` library for true semantic embedding of the user query.
- **Result aggregation**: in the current design each agent returns its own results. A future "aggregator" capability could let some agents collect and rank across their peers before responding to Emquest.
- **em_disco WebSocket clients**: any non-Erlang client (Python via EmPy, bots) that connects directly to em_disco WebSocket will need to migrate to the HTTP query endpoint. Not in scope for this spec.
