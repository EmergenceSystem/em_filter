# em_filter
[![Hex.pm](https://img.shields.io/hexpm/v/em_filter.svg?color=darkgreen)](https://hex.pm/packages/em_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/em_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

An Erlang library for building Emergence agents connected to an `em_disco` discovery service.

## Philosophy

Emergence is a distributed discovery network, not a search engine with a central index. Any agent can contribute any result type. Emquest (the web gateway) fans out queries across all connected agents in parallel, deduplicates results by URL, and streams cards to the browser in real time.

em_filter is the library side of this: it handles the WebSocket connection to em_disco, receives queries, calls your handler, and sends results back. Your handler focuses entirely on one thing — turning a query into a list of result maps (embryos).

## Features

- Connects your agent to one or more `em_disco` nodes configured in `emergence.conf` over persistent WebSockets
- Automatically registers on startup and reconnects on failure
- Announces agent capabilities to the `em_disco` registry via `agent_hello`
- Optional persistent memory (ETS) passed across queries
- Full set of HTML scraping utilities included

## Concepts

Every node in the Emergence system is an **agent**. An agent has two optional features:

- **Capabilities** — a list of strings (`<<"rss">>`, `<<"dns">>`, …) announced to `em_disco` at startup. Used by disco to route queries to relevant agents only.
- **Memory** — a map passed to `handle/2` on every query and updated with the returned value.
  - `ram` (default): lives in the process state, resets to `#{}` on restart.
  - `ets`: persisted in a local ETS table, survives worker restarts within the same BEAM session.

Memory is best used for caching expensive operations (HTTP responses, DNS lookups, rate limit state).
**Do not use memory to deduplicate results** — deduplication is handled upstream by the Emquest pipeline.

### Handler contract

Every handler module must export `handle/2`:

```erlang
handle(Body :: binary(), Memory :: map()) ->
    {Result :: term(), NewMemory :: map()}
```

`Body` is the raw JSON query binary. `Result` is typically a list of embryo maps.
Returning the same map as `NewMemory` is valid for stateless behaviour.

### Embryo format

Agents return a list of embryo maps:

```erlang
#{
    <<"type">>       => <<"rss">>,        %% agent-defined type
    <<"properties">> => #{
        <<"url">>    => <<"https://...">>,
        <<"title">>  => <<"...">>,
        <<"resume">> => <<"...">>
    }
}
```

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {em_filter, "1.2.4"}
]}.
```

## Usage

### Stateless agent

Announces capabilities but does not persist state between queries.

```erlang
em_filter:start_agent(my_agent, my_handler, #{
    capabilities => [<<"search">>, <<"web">>]
}).
```

```erlang
-module(my_handler).
-export([handle/2]).

handle(Body, Memory) ->
    Results = do_search(Body),
    {Results, Memory}.
```

### Agent with memory (cache)

Memory is useful for caching.

```erlang
-module(my_handler).
-export([handle/2]).

handle(Body, Memory) ->
    Cache = maps:get(cache, Memory, #{}),
    case maps:get(Body, Cache, undefined) of
        undefined ->
            Results  = fetch_from_api(Body),
            NewCache = Cache#{Body => Results},
            {Results, Memory#{cache => NewCache}};
        Cached ->
            {Cached, Memory}
    end.
```

```erlang
em_filter:start_agent(my_agent, my_handler, #{
    capabilities => [<<"search">>],
    memory       => ets
}).
```

## Multi-disco connectivity

An agent connects to every disco node listed in `emergence.conf`.
Each node gets its own persistent WebSocket connection and worker process.

```ini
[em_disco]
nodes = localhost:8080, em-disco.roques.me
```

With this config, `start_agent/3` spawns two workers automatically:
- `my_agent_server` — connected to local disco (index 1)
- `my_agent_server_2` — connected to public disco (index 2)

Port and transport resolution:
- `localhost` / `127.0.0.1` → port 8080, plain TCP (default)
- any other host without port → port 443, TLS (default)
- explicit port 443 → TLS
- any other explicit port → plain TCP

## Configuration

The `em_disco` address is resolved in this order:

1. `[em_disco] nodes` in `emergence.conf` (recommended)
2. `EM_DISCO_HOST` / `EM_DISCO_PORT` environment variables (legacy, single node)
3. Default: `localhost:8080`

`emergence.conf` locations:
- Linux/macOS: `~/.config/emergence/emergence.conf`
- Windows: `%APPDATA%\emergence\emergence.conf`

Full example:

```ini
[em_disco]
nodes = localhost:8080, em-disco.roques.me
```

## Console output

When running, em_filter logs two events at the `notice` level:

```
[em_filter] agent connected: my_agent @ localhost:8080
[em_filter] query: <body>
```

Connection warnings (auth rejected, timeout, unreachable) are logged at the `warning` level. OTP startup progress reports are suppressed.

## HTML utilities

The following helpers are available for agents that scrape HTML:

| Function | Description |
|---|---|
| `strip_scripts/1` | Removes `<script>` tags |
| `extract_elements/2` | CSS-style element extraction |
| `get_text/1` | Strips all HTML tags |
| `extract_attribute/2` | Extracts a tag attribute value |
| `clean_text/3` | Strips noise and decodes entities |
| `decode_html_entities/1` | Decodes `&amp;`, `&#x...;`, `&#...;` |
| `should_skip_link/2` | Filters out unwanted URLs |

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
