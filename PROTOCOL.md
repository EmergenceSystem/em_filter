# em_filter — Client Protocol Reference

**Version:** 1.0.0
**Role:** Client (agent)
**Counterpart:** em_disco (server)
**Transport:** WebSocket (RFC 6455) over TCP or TLS
**Encoding:** JSON (UTF-8)

---

## 1. Connection

```
ws://<host>:<port>/ws?token=<jwt>
```

The `token` query parameter is mandatory when the em_disco node has JWT
authentication enabled (the default). Connections without a valid token
are rejected with HTTP 401.

`em_filter_server` reads the token from (in priority order):

1. `jwt_token` key in the agent Config map passed to `em_filter:start_agent/3`
2. `jwt_token` application env in the `em_filter` application config

If no token is configured the server connects without a token, which
will be rejected with 401. The server logs a warning and schedules a
reconnect after `reconnect_interval_ms`.

---

## 2. Handshake

Both steps are always sent immediately after a successful WebSocket
upgrade, regardless of whether any capabilities are declared.

### Step 1 — Register

```json
Agent → Disco:  {"action": "register", "name": "<agent_name>"}
Disco → Agent:  {"status": "ok", "action": "registered"}
```

`name` must match the `sub` claim of the JWT exactly (case-sensitive).

Error responses:

| reason          | meaning                           |
|-----------------|-----------------------------------|
| `name_mismatch` | JWT `sub` does not match `name`   |
| `name_taken`    | Another agent with that name is already registered |

### Step 2 — Announce capabilities

```json
Agent → Disco:  {"action": "agent_hello", "capabilities": ["<cap>", ...]}
Disco → Agent:  {"status": "ok", "action": "agent_registered", "capabilities": [...]}
```

`capabilities` may be an empty array `[]`. This step is **always sent**,
even with an empty list, so the agent appears in the em_disco registry
and is eligible to receive broadcast queries.

---

## 3. Query / Result Cycle

After the handshake em_disco forwards query frames:

```json
Disco → Agent:  {"action": "query", "id": "<base64-id>", "body": "<query>"}
```

The agent **must** reply with the same `id`:

```json
Agent → Disco:  {"action": "result", "id": "<query-id>", "data": <result>}
```

`data` is whatever value the handler module's `handle/2` returns as its
first element — any JSON-encodable Erlang term (map, list, binary,
integer, boolean, or null).

em_disco applies a server-side timeout (default 5 000 ms). If no
response arrives before the deadline the query result is silently
discarded.

---

## 4. Handler Contract

Every handler module must export:

```erlang
handle(Body :: binary(), Memory :: map()) ->
    {Result :: term(), NewMemory :: map()}
```

- `Body` is the query string from the em_disco `query` frame.
- `Memory` is always a live map (never `undefined`).
- `Result` must be a JSON-encodable Erlang term. It is placed as-is
  into the `data` field of the result frame.
- Returning the same map as `NewMemory` is valid for stateless handlers.

---

## 5. Reconnection

`em_filter_server` does **not** stop the gen_server process on connection
loss. On `gun_down` or WS close it schedules `self() ! connect` after
`reconnect_interval_ms` milliseconds and retries the full
connect → upgrade → handshake sequence.

ETS memory (if configured) survives reconnection because it is owned
by the server process, not the gun connection.

---

## 6. Agent Config Map Keys

All keys are optional.

| Key            | Type                              | Default       | Description |
|----------------|-----------------------------------|---------------|-------------|
| `capabilities` | `[binary()]`                      | `[]`          | Capabilities announced via `agent_hello`. Used by em_disco to route queries. |
| `memory`       | `ram \| ets`                      | `ram`         | Memory backend. `ets` persists across worker restarts within the same BEAM session. `ram` resets to `#{}` on restart. |
| `jwt_token`    | `binary()`                        | app env       | JWT for WebSocket authentication. Overrides the application-level default. |
| `disco_nodes`  | `[{Host, Port, Transport}]`       | config/env    | Explicit node list, bypassing emergence.conf and environment variables. Primarily useful in tests. |

---

## 7. Application Config Keys

Configured in `sys.config` under the `em_filter` application:

| Key                    | Type                | Default | Description |
|------------------------|---------------------|---------|-------------|
| `jwt_token`            | `binary() \| undefined` | `undefined` | Default JWT used when not specified per-agent. |
| `reconnect_interval_ms` | `pos_integer()`    | `5000`  | Delay between reconnect attempts after connection loss. |
| `connect_timeout_ms`   | `pos_integer()`     | `5000`  | `gun:await_up` timeout. |
| `upgrade_timeout_ms`   | `pos_integer()`     | `5000`  | WebSocket upgrade receive timeout. |

---

## 8. Server Naming

Workers started by `em_filter_sup:start_agent/3` are registered under:

| Condition        | Registered name            |
|------------------|----------------------------|
| Single disco node (default) | `<agent_name>_server` |
| Second node      | `<agent_name>_server_2`    |
| N-th node        | `<agent_name>_server_<N>`  |

This ensures `whereis(my_agent_server)` works for the common
single-node deployment.

---

## 9. Node Discovery

Discovery order for `em_filter_sup`:

1. `disco_nodes` key in the agent Config map (per-agent override).
2. `EM_DISCO_HOST` / `EM_DISCO_PORT` environment variables.
3. `[em_disco]` section in `$HOME/.config/emergence/emergence.conf`
   (Linux/macOS) or `%APPDATA%\emergence\emergence.conf` (Windows).
4. Default: `[{"localhost", 8080, tcp}]`.

Port/transport resolution when no explicit port is given:

| Host            | Default port | Transport |
|-----------------|-------------|-----------|
| `localhost`     | 8080        | tcp       |
| `127.0.0.1`     | 8080        | tcp       |
| any other host  | 443         | tls       |

TLS uses the system CA store with SNI set to the target host, so
standard and wildcard certificates are validated correctly.
