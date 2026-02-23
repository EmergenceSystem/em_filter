# em_filter
[![Hex.pm](https://img.shields.io/hexpm/v/em_filter.svg?color=darkgreen)](https://hex.pm/packages/em_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/em_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

An Erlang library for building Emergence agents connected to an `em_disco` discovery service.

## Features

- Connects your agent to `em_disco` over a persistent WebSocket
- Automatically registers on startup and reconnects on failure
- Announces agent capabilities to the `em_disco` registry via `agent_hello`
- Optional persistent memory (ETS) passed across queries
- Full set of HTML scraping utilities included

## Concepts

Every node in the Emergence system is an **agent**. The Queen connects to `em_disco` the same way any other agent does.

An agent has two optional features:

- **Capabilities** — a list of strings (`<<"summarize">>`, `<<"llm">>`, …) announced to `em_disco` at startup. The Queen reads `GET /registry` to discover them.
- **Memory** — a map passed to `handle/2` on every query and updated with the returned value.
  - `ram` (default): lives in the process state, resets to `#{}` on restart.
  - `ets`: persisted in a local ETS table, survives worker restarts within the same BEAM session.

### Handler contract

Every handler module must export `handle/2`:

```erlang
handle(Body :: binary(), Memory :: map()) ->
    {Result :: term(), NewMemory :: map()}
```

Returning the same map as `NewMemory` is valid for stateless behaviour — no special config needed.

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {em_filter, "1.2.0"}
]}.
```

## Usage

### Stateless agent

Announces capabilities but does not persist state between queries.

```erlang
em_filter:start_agent(my_agent, my_handler, #{
    capabilities => [<<"summarize">>, <<"llm">>]
}).
```

```erlang
-module(my_handler).
-export([handle/2]).

handle(Body, Memory) ->
    Result = do_work(Body),
    {json:encode(Result), Memory}.  % Memory returned unchanged
```

### Agent with persistent memory

`handle/2` receives the current memory map and returns `{Result, NewMemory}`.
The updated memory is stored and passed on the next query.

```erlang
-module(my_agent).
-export([handle/2]).

handle(Body, Memory) ->
    Seen   = maps:get(seen, Memory, []),
    Result = do_work(Body, Seen),
    {json:encode(Result), Memory#{seen => [Body | Seen]}}.
```

```erlang
em_filter:start_agent(my_agent, my_agent, #{
    capabilities => [<<"summarize">>],
    memory       => ets
}).
```

### The Queen

The Queen is just an agent with an `orchestrate` capability — no special API.

```erlang
em_filter:start_agent(queen, queen_handler, #{
    capabilities => [<<"orchestrate">>],
    memory       => ets
}).
```

## Configuration

The `em_disco` address is resolved in this order:

1. Environment variables `EM_DISCO_HOST` / `EM_DISCO_PORT`
2. `~/.config/emergence/emergence.conf` (Linux/macOS) or `%APPDATA%\emergence\emergence.conf` (Windows)
3. Defaults: `localhost:8080`

`emergence.conf` example:

```ini
[em_disco]
host = 192.168.1.10
port = 8080
```

## HTML utilities

The following helpers are available for agents that scrape HTML:

| Function | Description |
|---|---|
| `strip_scripts/1` | Removes `<script>` tags |
| `extract_elements/2` | CSS-style element extraction |
| `get_text/1` | Strips all HTML tags |
| `extract_attribute/2` | Extracts a tag attribute value |
| `clean_text/3` | Strips noise and decodes entities |
| `decode_html_entities/1` | Decodes `&amp;`, `&#x…;`, `&#…;` |
| `should_skip_link/2` | Filters out unwanted URLs |

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
