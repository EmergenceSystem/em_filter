# em_filter
[![Hex.pm](https://img.shields.io/hexpm/v/em_filter.svg?color=darkgreen)](https://hex.pm/packages/em_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/em_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

An Erlang library for building Emergence filters and agents connected to an `em_disco` discovery service.

## Features

- Connects your filter or agent to `em_disco` over a persistent WebSocket
- Automatically registers on startup and reconnects on failure
- Optionally announces agent capabilities to the `em_disco` registry
- Optionally enables per-agent memory (ETS) passed across queries
- Full set of HTML scraping utilities included

## Concepts

**Filter** — stateless node. Receives a query, returns results, remembers nothing. This is the 1.0.0 behaviour, unchanged.

**Agent** — extends a filter with two optional features:
- **Capabilities** — a list of strings (`<<"summarize">>`, `<<"llm">>`, …) announced to `em_disco` at startup via `agent_hello`. The Queen agent reads `GET /registry` to discover them.
- **Memory** — a persistent map passed to `handle/2` on every query and updated with the returned value. Backed by a local ETS table.

A filter started without capabilities or memory is identical to a 1.0.0 filter.

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {em_filter, "1.1.0"}
]}.
```

## Usage

### Plain filter (unchanged from 1.0.0)

```erlang
-module(my_filter).
-export([handle/1]).

handle(Body) ->
    %% fetch, scrape, compute — return a JSON-encodable term
    json:encode(#{<<"embryo_list">> => []}).
```

```erlang
em_filter:start_filter(my_filter, my_filter).
```

### Agent with capabilities (no memory)

Announces itself to `em_disco` so the Queen can find it via `GET /registry`.
`handle/1` is still used — behaviour is stateless.

```erlang
em_filter:start_agent(my_agent, my_handler, #{
    capabilities => [<<"summarize">>, <<"llm">>]
}).
```

### Agent with memory

`handle/2` receives the current memory map and must return `{Result, NewMemory}`.
The updated memory is stored in a local ETS table and passed on the next query.

```erlang
-module(my_agent).
-export([handle/2]).

handle(Body, Memory) ->
    Seen    = maps:get(seen, Memory, []),
    Result  = do_work(Body, Seen),
    NewMem  = Memory#{seen => [Body | Seen]},
    {json:encode(Result), NewMem}.
```

```erlang
em_filter:start_agent(my_agent, my_agent, #{
    capabilities => [<<"summarize">>],
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

The following helpers are available for filters that scrape HTML:

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
