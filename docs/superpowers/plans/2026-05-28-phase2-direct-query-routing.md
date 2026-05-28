# Phase 2 — Direct Query Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `query_port` HTTP endpoint to each em_filter agent and give Emquest its own em_pop node for parallel peer-based dispatch — implementing Phase 2a and 2b of the em_disco → em_pop transition.

**Architecture:** Part A extends each em_filter agent with an optional `POST /agent/query` Cowboy listener; the agent's `query_port` is embedded in em_pop gossip payloads so any peer discovers it automatically. Part B wires Emquest with its own em_pop node (`max_peers=5000`), seeded from the `[em_disco]` bootstrap, and augments the existing disco fan-out with a parallel em_pop fan-out whose results are merged before deduplication.

**Tech Stack:** Erlang/OTP, Cowboy 2.12.0, kvex 0.2.1, Common Test

---

## File Map

### Part A — em_filter (dir: `filters/em_filter/`)

| Action | File |
|--------|------|
| Modify | `src/em_pop_node.erl` — add `query_port` to `#peer{}` and `#state{}`, extend all serialization |
| **Create** | `src/em_filter_http.erl` — Cowboy handler for `POST /agent/query` |
| Modify | `src/em_filter_server.erl` — add `handle_call({http_query, Query}, ...)` |
| Modify | `src/em_filter_sup.erl` — add `maybe_start_query_listener/2`, wire into `start_agent/3` and `stop_agent/1` |
| Modify | `src/em_filter.app.src` — bump vsn to `"1.4.0"`, add `em_filter_http` to modules |
| **Create** | `test/echo_handler.erl` — minimal test handler (echo query back) |
| **Create** | `test/em_pop_node_query_port_SUITE.erl` — CT tests for query_port in gossip payloads |
| **Create** | `test/em_filter_query_SUITE.erl` — CT tests for end-to-end HTTP query path |

### Part B — Emquest (dir: `emquest/`)

| Action | File |
|--------|------|
| Modify | `rebar.config` — add `{kvex, "0.2.1"}` |
| **Copy** | `src/em_pop_node.erl` from em_filter |
| **Copy** | `src/em_pop_http.erl` from em_filter |
| **Copy** | `src/em_filter_vec.erl` from em_filter |
| Modify | `src/queen.erl` — add `pop_seeds/0` and `emquest_pop_port/0` |
| **Create** | `src/emquest_pop.erl` — gen_server owning Emquest's em_pop node |
| Modify | `src/emquest_sup.erl` — start `emquest_pop` as a supervised child |
| Modify | `src/emquest_handler.erl` — parallel dispatch via em_pop peers + disco, merged before dedup |
| Modify | `src/emquest.app.src` — bump vsn, add `kvex` to applications, list new modules |
| **Create** | `test/queen_pop_seeds_SUITE.erl` — CT tests for `queen:pop_seeds/0` |
| **Create** | `test/emquest_pop_SUITE.erl` — CT tests for `emquest_pop` lifecycle and filtering |

---

## Tasks — Part A: em_filter

---

### Task 1: Add `query_port` to em_pop_node records and serialization

**Files:**
- Modify: `filters/em_filter/src/em_pop_node.erl`
- Create: `filters/em_filter/test/em_pop_node_query_port_SUITE.erl`

---

- [ ] **Step 1: Write the failing tests**

Create `filters/em_filter/test/em_pop_node_query_port_SUITE.erl`:

```erlang
-module(em_pop_node_query_port_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([query_port_present_in_payload/1,
         query_port_null_when_absent/1,
         peer_map_exposes_query_port/1]).

all() ->
    [query_port_present_in_payload,
     query_port_null_when_absent,
     peer_map_exposes_query_port].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    Config.

end_per_suite(_Config) -> ok.

%% When query_port is set in Opts, it appears in the node's gossip payload.
query_port_present_in_payload(_Config) ->
    Vec  = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19201,
                                          query_port      => 19202,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    %% Trigger a gossip exchange so the node serialises its state.
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    %% The node must report its query_port in the response.
    19202 = maps:get(<<"query_port">>, Payload),
    exit(Pid, shutdown),
    ok.

%% When query_port is absent from Opts, the payload carries null.
query_port_null_when_absent(_Config) ->
    Vec  = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19203,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    null = maps:get(<<"query_port">>, Payload),
    exit(Pid, shutdown),
    ok.

%% query_port from a remote peer is captured in the peer map returned
%% by get_peers/1 after an add_peer call.
peer_map_exposes_query_port(_Config) ->
    Vec = em_filter_vec:from_capabilities([<<"web">>]),
    %% Start a "remote" node that advertises query_port 19205.
    {ok, Remote} = em_pop_node:start_link(#{port            => 19204,
                                             query_port      => 19205,
                                             vector          => Vec,
                                             gossip_interval => 0}),
    %% Start a "local" node with no query_port.
    {ok, Local}  = em_pop_node:start_link(#{port            => 19206,
                                             vector          => Vec,
                                             gossip_interval => 0}),
    %% Local contacts Remote — gets its query_port in the gossip response.
    ok = em_pop_node:add_peer(Local, "127.0.0.1", 19204),
    [PeerMap] = em_pop_node:get_peers(Local),
    %% The map must expose query_port under the atom key (public API).
    19205 = maps:get(query_port, PeerMap),
    exit(Remote, shutdown),
    exit(Local, shutdown),
    ok.
```

- [ ] **Step 2: Run tests — expect failure**

```
cd filters/em_filter && rebar3 ct --suite em_pop_node_query_port_SUITE
```

Expected: compile error or test failure because `query_port` is not in the records yet.

- [ ] **Step 3: Add `query_port` to `#peer{}` in `src/em_pop_node.erl`**

Replace:
```erlang
-record(peer, {
    id          :: binary(),          %% 16-byte unique identifier
    host        :: binary(),          %% hostname or IP (binary string)
    port        :: inet:port_number(),%% TCP port of the peer's gossip listener
    vector      :: binary(),          %% capability vector (f32 flat binary)
    trust = 0.0 :: float(),           %% trust score in [0.0, 1.0]
    last_seen   :: integer()          %% erlang:monotonic_time(millisecond)
}).
```
With:
```erlang
-record(peer, {
    id                     :: binary(),           %% 16-byte unique identifier
    host                   :: binary(),           %% hostname or IP (binary string)
    port                   :: inet:port_number(), %% TCP port of the peer's gossip listener
    query_port = undefined :: pos_integer() | undefined,  %% direct HTTP query port (null if not exposed)
    vector                 :: binary(),           %% capability vector (f32 flat binary)
    trust = 0.0            :: float(),            %% trust score in [0.0, 1.0]
    last_seen              :: integer()           %% erlang:monotonic_time(millisecond)
}).
```

- [ ] **Step 4: Add `query_port` to `#state{}`**

Replace:
```erlang
-record(state, {
    id              :: binary(),                    %% this node's unique ID
    host = <<"localhost">> :: binary(),             %% advertised hostname
    port            :: inet:port_number(),          %% gossip HTTP listener port
    vector          :: binary(),                    %% this node's capability vector
    peers = #{}     :: #{binary() => #peer{}},      %% known peers by ID
    kvex_ix         :: term(),                      %% kvex cosine-search index
    stale_timeout   :: pos_integer(),               %% peer eviction threshold (ms)
    gossip_interval :: non_neg_integer(),           %% background tick interval (ms)
    max_peers       :: pos_integer()                %% peer list capacity
}).
```
With:
```erlang
-record(state, {
    id                          :: binary(),                   %% this node's unique ID
    host = <<"localhost">>      :: binary(),                   %% advertised hostname
    port                        :: inet:port_number(),         %% gossip HTTP listener port
    query_port = undefined      :: pos_integer() | undefined,  %% direct HTTP query port (null if not exposed)
    vector                      :: binary(),                   %% this node's capability vector
    peers = #{}                 :: #{binary() => #peer{}},     %% known peers by ID
    kvex_ix                     :: term(),                     %% kvex cosine-search index
    stale_timeout               :: pos_integer(),              %% peer eviction threshold (ms)
    gossip_interval             :: non_neg_integer(),          %% background tick interval (ms)
    max_peers                   :: pos_integer()               %% peer list capacity
}).
```

- [ ] **Step 5: Extract `query_port` in `init/1`**

Replace:
```erlang
    Port    = maps:get(port,            Opts),
    Vec     = maps:get(vector,          Opts),
    StaleT  = maps:get(stale_timeout,   Opts, ?DEFAULT_STALE_TIMEOUT),
    GossipI = maps:get(gossip_interval, Opts, ?DEFAULT_GOSSIP_INTERVAL),
    MaxP    = maps:get(max_peers,       Opts, ?DEFAULT_MAX_PEERS),
```
With:
```erlang
    Port      = maps:get(port,            Opts),
    Vec       = maps:get(vector,          Opts),
    StaleT    = maps:get(stale_timeout,   Opts, ?DEFAULT_STALE_TIMEOUT),
    GossipI   = maps:get(gossip_interval, Opts, ?DEFAULT_GOSSIP_INTERVAL),
    MaxP      = maps:get(max_peers,       Opts, ?DEFAULT_MAX_PEERS),
    QueryPort = maps:get(query_port,      Opts, undefined),
```

Replace the state construction at the end of `init/1`:
```erlang
    {ok, #state{
        id              = Id,
        port            = Port,
        vector          = Vec,
        kvex_ix         = Ix,
        stale_timeout   = StaleT,
        gossip_interval = GossipI,
        max_peers       = MaxP
    }}.
```
With:
```erlang
    {ok, #state{
        id              = Id,
        port            = Port,
        query_port      = QueryPort,
        vector          = Vec,
        kvex_ix         = Ix,
        stale_timeout   = StaleT,
        gossip_interval = GossipI,
        max_peers       = MaxP
    }}.
```

- [ ] **Step 6: Update `state_to_payload/1` to include `query_port`**

Replace:
```erlang
state_to_payload(#state{id = Id, host = Host, port = Port,
                         vector = Vec, peers = Peers}) ->
    #{<<"id">>     => base64:encode(Id),
      <<"host">>   => Host,
      <<"port">>   => Port,
      <<"vector">> => base64:encode(Vec),
      %% Include our own peer list so the remote can discover them too.
      <<"peers">>  => [peer_to_payload(P) || P <- maps:values(Peers)]}.
```
With:
```erlang
state_to_payload(#state{id = Id, host = Host, port = Port,
                         query_port = QPort,
                         vector = Vec, peers = Peers}) ->
    #{<<"id">>         => base64:encode(Id),
      <<"host">>       => Host,
      <<"port">>       => Port,
      <<"query_port">> => case QPort of undefined -> null; P -> P end,
      <<"vector">>     => base64:encode(Vec),
      %% Include our own peer list so the remote can discover them too.
      <<"peers">>      => [peer_to_payload(P) || P <- maps:values(Peers)]}.
```

- [ ] **Step 7: Update `peer_to_payload/1` to include `query_port`**

Replace:
```erlang
peer_to_payload(#peer{id = Id, host = H, port = P, vector = V, trust = T}) ->
    #{<<"id">>     => base64:encode(Id),
      <<"host">>   => H,
      <<"port">>   => P,
      <<"vector">> => base64:encode(V),
      <<"trust">>  => T}.
```
With:
```erlang
peer_to_payload(#peer{id = Id, host = H, port = P, query_port = QP,
                      vector = V, trust = T}) ->
    #{<<"id">>         => base64:encode(Id),
      <<"host">>       => H,
      <<"port">>       => P,
      <<"query_port">> => case QP of undefined -> null; Q -> Q end,
      <<"vector">>     => base64:encode(V),
      <<"trust">>      => T}.
```

- [ ] **Step 8: Update `payload_to_peer/1` to extract `query_port`**

Replace:
```erlang
payload_to_peer(#{<<"id">>     := Id,
                  <<"host">>   := Host,
                  <<"port">>   := Port,
                  <<"vector">> := Vec}) ->
    #peer{
        id        = base64:decode(Id),
        host      = Host,
        port      = Port,
        vector    = base64:decode(Vec),
        %% Set last_seen to now — we just heard from this node.
        last_seen = erlang:monotonic_time(millisecond)
    }.
```
With:
```erlang
payload_to_peer(#{<<"id">>     := Id,
                  <<"host">>   := Host,
                  <<"port">>   := Port,
                  <<"vector">> := Vec} = Map) ->
    QPort = case maps:get(<<"query_port">>, Map, null) of
        null -> undefined;
        P    -> P
    end,
    #peer{
        id         = base64:decode(Id),
        host       = Host,
        port       = Port,
        query_port = QPort,
        vector     = base64:decode(Vec),
        %% Set last_seen to now — we just heard from this node.
        last_seen  = erlang:monotonic_time(millisecond)
    }.
```

- [ ] **Step 9: Update `peer_to_map/1` to include `query_port`**

Replace:
```erlang
peer_to_map(#peer{id = Id, host = H, port = P,
                  vector = V, trust = T, last_seen = LS}) ->
    #{id        => Id,
      host      => H,
      port      => P,
      vector    => V,
      trust     => T,
      last_seen => LS}.
```
With:
```erlang
peer_to_map(#peer{id = Id, host = H, port = P,
                  query_port = QP,
                  vector = V, trust = T, last_seen = LS}) ->
    #{id         => Id,
      host       => H,
      port       => P,
      query_port => QP,
      vector     => V,
      trust      => T,
      last_seen  => LS}.
```

- [ ] **Step 10: Run tests — expect pass**

```
cd filters/em_filter && rebar3 ct --suite em_pop_node_query_port_SUITE
```

Expected: All 3 tests green.

- [ ] **Step 11: Commit**

```bash
cd filters/em_filter
git add src/em_pop_node.erl test/em_pop_node_query_port_SUITE.erl
git commit -m "feat(em_pop_node): add query_port to peer and state — Phase 2a gossip extension"
```

---

### Task 2: Create `em_filter_http.erl` — direct query Cowboy handler

**Files:**
- Create: `filters/em_filter/src/em_filter_http.erl`
- Create: `filters/em_filter/test/echo_handler.erl` (test helper)

The handler is thin: decode request → delegate to gen_server → encode response. Full correctness is validated end-to-end in Task 3.

- [ ] **Step 1: Create `test/echo_handler.erl`** (needed as a test agent handler)

```erlang
%%%-------------------------------------------------------------------
%%% @doc Minimal test handler — echoes the query back as a JSON list.
%%% Used only in Common Test suites.
%%% @end
%%%-------------------------------------------------------------------
-module(echo_handler).
-export([handle/2]).

%% Returns a JSON array containing one map: {"echo": "<query>"}.
%% Result is a binary (JSON-encoded), matching the real handler contract.
-spec handle(binary(), map()) -> {binary(), map()}.
handle(Query, Memory) ->
    Result = iolist_to_binary(json:encode([#{<<"echo">> => Query}])),
    {Result, Memory}.
```

- [ ] **Step 2: Create `src/em_filter_http.erl`**

```erlang
%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter_http — Cowboy handler for the direct agent query endpoint.
%%%
%%% Route: POST /agent/query
%%%
%%% This handler is the network entry point for Emquest's em_pop-based
%%% direct dispatch.  When Emquest finds this agent via kvex similarity
%%% search and decides to query it directly, the HTTP request lands here.
%%%
%%% Request body (JSON):
%%%   {"query": "<user query text>"}
%%%
%%% Success response — HTTP 200:
%%%   {"results": <agent handler output>}
%%%
%%% where `<agent handler output>' is whatever `handler:handle/2' returns
%%% (a JSON-encoded binary), decoded once so it is properly nested in
%%% the response JSON rather than appearing as an escaped string.
%%%
%%% Error responses:
%%%   400 — malformed JSON or missing "query" field
%%%   500 — internal handler error or gen_server call timeout
%%%
%%% The Cowboy route options map MUST contain:
%%%   `server' => atom()  — registered name of the em_filter_server
%%%                          (always `<agent>_server' for index 1)
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_http).
-behaviour(cowboy_handler).
-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Handle one POST /agent/query request.
%%
%% Reads the full body, extracts the "query" field, calls the local
%% agent gen_server synchronously (30 s timeout), and returns the
%% result as JSON.
%%
%% The handler's raw output is decoded before embedding in the response
%% so that the result is a proper JSON value rather than an escaped
%% string:
%%
%%   handler returns:  <<"[{\"url\":\"...\"}]">>   (binary)
%%   response body:    {"results": [{"url": "..."}]}
%%
%% @end
%%--------------------------------------------------------------------
init(Req0, #{server := ServerName} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    try
        #{<<"query">> := Query} = json:decode(Body),
        case gen_server:call(ServerName, {http_query, Query}, 30_000) of
            {ok, RawResult} ->
                %% Decode the handler's JSON output so it nests cleanly.
                Decoded  = try json:decode(RawResult)
                           catch _:_ -> RawResult end,
                RespBody = iolist_to_binary(
                    json:encode(#{<<"results">> => Decoded})),
                Req2 = cowboy_req:reply(200,
                    #{<<"content-type">> => <<"application/json">>},
                    RespBody, Req1),
                {ok, Req2, State};
            {error, Reason} ->
                Msg  = iolist_to_binary(io_lib:format("~p", [Reason])),
                Req2 = cowboy_req:reply(500,
                    #{<<"content-type">> => <<"application/json">>},
                    iolist_to_binary(
                        json:encode(#{<<"error">> => Msg})),
                    Req1),
                {ok, Req2, State}
        end
    catch
        %% Malformed JSON or missing "query" key.
        _:_ ->
            ErrReq = cowboy_req:reply(400, #{},
                <<"{\"error\":\"body must be JSON with a 'query' field\"}">>,
                Req1),
            {ok, ErrReq, State}
    end.
```

- [ ] **Step 3: Verify compilation**

```
cd filters/em_filter && rebar3 compile
```

Expected: `===> Compiling em_filter_http` among the output, no errors.

---

### Task 3: Add `http_query` handle_call to `em_filter_server`

**Files:**
- Modify: `filters/em_filter/src/em_filter_server.erl`

- [ ] **Step 1: Replace the catch-all `handle_call/3`**

The current catch-all is:
```erlang
-spec handle_call(term(), {pid(), term()}, #state{}) -> {reply, ok, #state{}}.
handle_call(_Req, _From, State) -> {reply, ok, State}.
```

Replace with two clauses:
```erlang
%%--------------------------------------------------------------------
%% @doc Handle a direct HTTP query forwarded by em_filter_http.
%%
%% Delegates to the same `dispatch/2' function used by the WebSocket
%% path.  The agent's handler module and memory are therefore shared
%% between both transports — the caller's transport is invisible to
%% the handler.
%%
%% Returns `{ok, Result}' where Result is the JSON binary produced by
%% `handler_module:handle/2'.  em_filter_http decodes this before
%% embedding it in its response body.
%% @end
%%--------------------------------------------------------------------
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, {ok, binary()} | ok, #state{}}.
handle_call({http_query, QueryBinary}, _From, State) ->
    {Result, NewState} = dispatch(QueryBinary, State),
    {reply, {ok, Result}, NewState};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.
```

- [ ] **Step 2: Verify compilation**

```
cd filters/em_filter && rebar3 compile
```

Expected: clean, no dialyzer warnings for the new spec.

---

### Task 4: Add `maybe_start_query_listener/2` to `em_filter_sup`

**Files:**
- Modify: `filters/em_filter/src/em_filter_sup.erl`

- [ ] **Step 1: Add the function**

Add after `maybe_start_pop_node/2` (around line 215), before the `%%==== Disco node resolution` section:

```erlang
%%--------------------------------------------------------------------
%% @private
%% @doc Optionally start a Cowboy HTTP listener for direct query routing.
%%
%% Only starts when Config contains a `query_port' key.  Agents without
%% this key are invisible to em_pop-based Emquest dispatch (they are
%% still reachable via the WebSocket bus during Phase 2).
%%
%% Route:  POST /agent/query  → em_filter_http #{server => ServerAtom}
%%
%% ServerAtom is `<agent>_server' — the primary worker (index 1).
%% All multi-node workers share the same query endpoint; the HTTP path
%% is stateless so no routing between workers is needed.
%%
%% `already_started' is accepted silently so `start_agent/3' may be
%% called again after a partial failure without crashing.  All other
%% errors are logged but do not abort agent startup.
%% @end
%%--------------------------------------------------------------------
-spec maybe_start_query_listener(atom(), map()) -> ok.
maybe_start_query_listener(AgentName, Config) ->
    case maps:get(query_port, Config, undefined) of
        undefined ->
            ok;
        QPort ->
            ServerAtom = list_to_atom(atom_to_list(AgentName) ++ "_server"),
            Dispatch = cowboy_router:compile([
                {'_', [{"/agent/query", em_filter_http,
                        #{server => ServerAtom}}]}
            ]),
            ListenerRef = {em_filter_query, AgentName},
            case cowboy:start_clear(ListenerRef, [{port, QPort}],
                                    #{env => #{dispatch => Dispatch}}) of
                {ok, _} ->
                    logger:info("[em_filter] query listener on port ~w for ~p",
                                [QPort, AgentName]);
                {error, {already_started, _}} ->
                    ok;
                {error, Reason} ->
                    logger:warning("[em_filter] query listener failed to start",
                                   #{agent => AgentName, reason => Reason})
            end,
            ok
    end.
```

- [ ] **Step 2: Call `maybe_start_query_listener/2` from `start_agent/3`**

Replace:
```erlang
    _ = maybe_start_pop_node(AgentName, Config),
    first_ok(Results).
```
With:
```erlang
    _ = maybe_start_pop_node(AgentName, Config),
    _ = maybe_start_query_listener(AgentName, Config),
    first_ok(Results).
```

- [ ] **Step 3: Stop the query listener in `stop_agent/1`**

In the `Ids ->` branch, replace:
```erlang
            Ids ->
                lists:foreach(fun(Id) ->
                    supervisor:terminate_child(?MODULE, Id),
                    supervisor:delete_child(?MODULE, Id)
                end, Ids),
                em_pop_sup:stop_node(AgentName),
                ok
```
With:
```erlang
            Ids ->
                lists:foreach(fun(Id) ->
                    supervisor:terminate_child(?MODULE, Id),
                    supervisor:delete_child(?MODULE, Id)
                end, Ids),
                em_pop_sup:stop_node(AgentName),
                catch cowboy:stop_listener({em_filter_query, AgentName}),
                ok
```

- [ ] **Step 4: Verify compilation**

```
cd filters/em_filter && rebar3 compile
```

Expected: clean.

---

### Task 5: Write end-to-end CT suite for the HTTP query path

**Files:**
- Create: `filters/em_filter/test/em_filter_query_SUITE.erl`

- [ ] **Step 1: Write the suite**

```erlang
-module(em_filter_query_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([valid_query_returns_200/1,
         bad_json_returns_400/1,
         missing_query_field_returns_400/1,
         query_port_embedded_in_gossip/1]).

all() ->
    [valid_query_returns_200,
     bad_json_returns_400,
     missing_query_field_returns_400,
     query_port_embedded_in_gossip].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    {ok, _Sup} = em_filter_sup:start_link(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    [{test_case, TestCase} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

%% POST /agent/query with a valid body returns 200 and {"results": [...]}.
valid_query_returns_200(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_echo, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],   %% disco not used
        query_port  => 19400,
        pop_port    => 19401,
        capabilities => [<<"echo">>]
    }),
    timer:sleep(150),   %% let the Cowboy listener bind
    Body    = <<"{\"query\": \"hello pop\"}">>,
    {ok, {{_, 200, _}, _, RespBin}} =
        httpc:request(post,
            {"http://localhost:19400/agent/query",
             [], "application/json", binary_to_list(Body)},
            [{timeout, 5000}], [{body_format, binary}]),
    #{<<"results">> := Results} = json:decode(RespBin),
    [#{<<"echo">> := <<"hello pop">>}] = Results,
    em_filter_sup:stop_agent(qtest_echo),
    ok.

%% Malformed JSON body → 400.
bad_json_returns_400(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_bad1, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        query_port  => 19410
    }),
    timer:sleep(150),
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post,
            {"http://localhost:19410/agent/query",
             [], "application/json", "not valid json"},
            [{timeout, 5000}], []),
    em_filter_sup:stop_agent(qtest_bad1),
    ok.

%% Valid JSON but no "query" key → 400.
missing_query_field_returns_400(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_bad2, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        query_port  => 19420
    }),
    timer:sleep(150),
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post,
            {"http://localhost:19420/agent/query",
             [], "application/json",
             "{\"text\": \"wrong key\"}"},
            [{timeout, 5000}], []),
    em_filter_sup:stop_agent(qtest_bad2),
    ok.

%% query_port configured on a node appears in its gossip payload.
query_port_embedded_in_gossip(_Config) ->
    Vec  = em_filter_vec:from_capabilities([<<"echo">>]),
    {ok, Pid} = em_pop_node:start_link(#{
        port            => 19430,
        query_port      => 19431,
        vector          => Vec,
        gossip_interval => 0
    }),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    19431 = maps:get(<<"query_port">>, Payload),
    exit(Pid, shutdown),
    ok.
```

- [ ] **Step 2: Run the suite**

```
cd filters/em_filter && rebar3 ct --suite em_filter_query_SUITE
```

Expected: All 4 tests pass. The `valid_query_returns_200` test may log WebSocket connection warnings (the agent tries to connect to `localhost:29999` which doesn't exist) — those are expected and don't affect the query_port listener.

- [ ] **Step 3: Run the full test suite — verify no regressions**

```
cd filters/em_filter && rebar3 ct
```

Expected: all existing suites continue to pass.

- [ ] **Step 4: Commit**

```bash
cd filters/em_filter
git add src/em_filter_http.erl \
        src/em_filter_server.erl \
        src/em_filter_sup.erl \
        test/echo_handler.erl \
        test/em_filter_query_SUITE.erl \
        test/em_pop_node_query_port_SUITE.erl
git commit -m "feat(em_filter): query_port HTTP endpoint for direct em_pop dispatch (Phase 2a)"
```

---

### Task 6: Update `em_filter.app.src`

**Files:**
- Modify: `filters/em_filter/src/em_filter.app.src`

- [ ] **Step 1: Bump version and add the new module**

Replace:
```erlang
    {vsn, "1.3.0"},
```
With:
```erlang
    {vsn, "1.4.0"},
```

Replace the modules list:
```erlang
    {modules, [
        em_filter_app,
        em_filter,
        em_filter_sup,
        em_filter_server,
        em_filter_vec,
        em_pop_sup,
        em_pop_node,
        em_pop_http
    ]},
```
With:
```erlang
    {modules, [
        em_filter_app,
        em_filter,
        em_filter_sup,
        em_filter_server,
        em_filter_http,
        em_filter_vec,
        em_pop_sup,
        em_pop_node,
        em_pop_http
    ]},
```

- [ ] **Step 2: Compile and commit**

```
cd filters/em_filter && rebar3 compile
```

```bash
cd filters/em_filter
git add src/em_filter.app.src
git commit -m "chore(em_filter): bump vsn to 1.4.0, register em_filter_http module"
```

---

## Tasks — Part B: Emquest

---

### Task 7: Add `kvex` to Emquest and copy em_pop sources

**Files:**
- Modify: `emquest/rebar.config`
- Copy: three source files from em_filter

- [ ] **Step 1: Write the failing build check**

```
cd emquest && rebar3 compile
```

Currently passes (kvex not yet added). After adding it, it must still pass — the "failure" here is that `em_pop_node` is undefined before copying.

- [ ] **Step 2: Add `kvex` to `emquest/rebar.config`**

Replace:
```erlang
{deps, [
    {cowboy, "2.12.0"},
    {mistral_handler, "0.2.0"},
    {openai_handler, "0.2.0"},
    {claude_handler, "0.2.0"},
    {ollama_handler, "0.2.0"}
]}.
```
With:
```erlang
{deps, [
    {cowboy,          "2.12.0"},
    {kvex,            "0.2.1"},
    {mistral_handler, "0.2.0"},
    {openai_handler,  "0.2.0"},
    {claude_handler,  "0.2.0"},
    {ollama_handler,  "0.2.0"}
]}.
```

- [ ] **Step 3: Copy em_pop source files**

```bash
cp filters/em_filter/src/em_pop_node.erl emquest/src/em_pop_node.erl
cp filters/em_filter/src/em_pop_http.erl emquest/src/em_pop_http.erl
cp filters/em_filter/src/em_filter_vec.erl emquest/src/em_filter_vec.erl
```

> **Note:** These are identical copies. When em_pop is extracted into a standalone Hex package, this duplication disappears. For now, keeping copies is simpler than managing a local path dependency.

- [ ] **Step 4: Fetch deps and compile**

```
cd emquest && rebar3 get-deps && rebar3 compile
```

Expected: kvex downloaded and compiled, all three new source files compile cleanly.

- [ ] **Step 5: Commit**

```bash
cd emquest
git add rebar.config src/em_pop_node.erl src/em_pop_http.erl src/em_filter_vec.erl
git commit -m "feat(emquest): add kvex dep and copy em_pop + em_filter_vec sources"
```

---

### Task 8: Add `pop_seeds/0` and `emquest_pop_port/0` to `queen.erl`

**Files:**
- Modify: `emquest/src/queen.erl`
- Create: `emquest/test/queen_pop_seeds_SUITE.erl`

`pop_seeds/0` returns `[{Host, PopPort}]` from `[em_disco] nodes` + `[em_disco] pop_port`.
`emquest_pop_port/0` returns the Emquest node's own gossip port from `[emquest] pop_port` (default 9100).

- [ ] **Step 1: Write the failing tests**

Create `emquest/test/queen_pop_seeds_SUITE.erl`:

```erlang
-module(queen_pop_seeds_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0]).
-export([pop_seeds_empty_without_pop_port/1,
         pop_seeds_parses_host_and_port/1,
         emquest_pop_port_defaults_to_9100/1]).

all() ->
    [pop_seeds_empty_without_pop_port,
     pop_seeds_parses_host_and_port,
     emquest_pop_port_defaults_to_9100].

%% When no conf file is found (or pop_port absent), pop_seeds returns [].
pop_seeds_empty_without_pop_port(_Config) ->
    %% Run in a temp dir with no conf so read_conf returns undefined.
    OldHome = os:getenv("HOME"),
    TmpDir  = filename:join(os:getenv("TEMP", "/tmp"),
                             "queen_test_empty_" ++
                             integer_to_list(erlang:unique_integer([positive]))),
    ok      = filelib:ensure_dir(filename:join(TmpDir, "x")),
    os:putenv("HOME", TmpDir),
    try
        [] = queen:pop_seeds()
    after
        case OldHome of
            false -> os:unsetenv("HOME");
            H     -> os:putenv("HOME", H)
        end,
        file:del_dir_r(TmpDir)
    end.

%% pop_seeds parses nodes + pop_port correctly.
pop_seeds_parses_host_and_port(Config) ->
    PrivDir = ?config(priv_dir, Config),
    ConfDir = filename:join([PrivDir, ".config", "emergence"]),
    ok      = filelib:ensure_dir(filename:join(ConfDir, "x")),
    ok      = file:write_file(
                  filename:join(ConfDir, "emergence.conf"),
                  "[em_disco]\nnodes = seed.example.com:8080\npop_port = 9000\n"),
    OldHome = os:getenv("HOME"),
    os:putenv("HOME", PrivDir),
    try
        Seeds = queen:pop_seeds(),
        true  = lists:member({"seed.example.com", 9000}, Seeds)
    after
        case OldHome of
            false -> os:unsetenv("HOME");
            H     -> os:putenv("HOME", H)
        end
    end.

%% emquest_pop_port/0 returns 9100 when [emquest] pop_port is absent.
emquest_pop_port_defaults_to_9100(_Config) ->
    OldHome = os:getenv("HOME"),
    TmpDir  = filename:join(os:getenv("TEMP", "/tmp"),
                             "queen_test_port_" ++
                             integer_to_list(erlang:unique_integer([positive]))),
    ok      = filelib:ensure_dir(filename:join(TmpDir, "x")),
    os:putenv("HOME", TmpDir),
    try
        9100 = queen:emquest_pop_port()
    after
        case OldHome of
            false -> os:unsetenv("HOME");
            H     -> os:putenv("HOME", H)
        end,
        file:del_dir_r(TmpDir)
    end.
```

- [ ] **Step 2: Run — expect failure**

```
cd emquest && rebar3 ct --suite queen_pop_seeds_SUITE
```

Expected: `undefined function queen:pop_seeds/0`.

- [ ] **Step 3: Add `pop_seeds/0` and `emquest_pop_port/0` to `queen.erl`**

Add both to the `-export` list. Current export line:
```erlang
-export([expand/1, rank/2, synthesize/2, disco_nodes/0,
         conf_path/0, parse_conf/1]).
```
Replace with:
```erlang
-export([expand/1, rank/2, synthesize/2, disco_nodes/0,
         pop_seeds/0, emquest_pop_port/0,
         conf_path/0, parse_conf/1]).
```

Add the two functions after `disco_nodes/0`, before `local_node_urls/1`:

```erlang
%%--------------------------------------------------------------------
%% @doc Return em_pop bootstrap seed endpoints from `emergence.conf'.
%%
%% Reads host entries from `[em_disco] nodes' and the shared gossip
%% port from `[em_disco] pop_port'.  Returns a `{Host, Port}' list
%% that `emquest_pop:init/1' uses to seed Emquest's peer table.
%%
%% Returns `[]' when `pop_port' is absent — em_pop seeding is skipped
%% and Emquest starts with an empty peer table (normal during early
%% Phase 2 deployment when not all seeds are upgraded yet).
%% @end
%%--------------------------------------------------------------------
-spec pop_seeds() -> [{string(), pos_integer()}].
pop_seeds() ->
    DiscoConf = read_disco_conf(),
    case maps:get("pop_port", DiscoConf, undefined) of
        undefined ->
            [];
        PortStr ->
            PopPort = list_to_integer(string:trim(PortStr)),
            Hosts   = extract_disco_hosts(DiscoConf),
            [{H, PopPort} || H <- Hosts]
    end.

%%--------------------------------------------------------------------
%% @doc Return the em_pop listener port for the Emquest node.
%%
%% Reads `[emquest] pop_port' from `emergence.conf'. Default: 9100.
%%
%% Example:
%%   [emquest]
%%   pop_port = 9100
%% @end
%%--------------------------------------------------------------------
-spec emquest_pop_port() -> pos_integer().
emquest_pop_port() ->
    case conf_path() of
        undefined ->
            9100;
        Path ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    Section = maps:get("emquest", parse_conf(Bin), #{}),
                    case maps:get("pop_port", Section, undefined) of
                        undefined -> 9100;
                        PortStr   -> list_to_integer(string:trim(PortStr))
                    end;
                _ ->
                    9100
            end
    end.

%% @private
%% @doc Extract bare hostnames from `[em_disco] nodes' (strips ports).
-spec extract_disco_hosts(map()) -> [string()].
extract_disco_hosts(Conf) ->
    NodesStr = maps:get("nodes", Conf,
                   maps:get("host", Conf, "localhost")),
    Entries  = string:split(NodesStr, ",", all),
    lists:filtermap(fun(Entry) ->
        case string:trim(Entry) of
            "" -> false;
            E  ->
                H = case string:split(E, ":", trailing) of
                    [Host, _Port] -> string:trim(Host);
                    [Host]        -> string:trim(Host)
                end,
                {true, H}
        end
    end, Entries).
```

- [ ] **Step 4: Run tests — expect pass**

```
cd emquest && rebar3 ct --suite queen_pop_seeds_SUITE
```

Expected: All 3 tests green.

- [ ] **Step 5: Commit**

```bash
cd emquest
git add src/queen.erl test/queen_pop_seeds_SUITE.erl
git commit -m "feat(queen): add pop_seeds/0 and emquest_pop_port/0 for em_pop bootstrap"
```

---

### Task 9: Create `emquest_pop.erl` gen_server

**Files:**
- Create: `emquest/src/emquest_pop.erl`
- Create: `emquest/test/emquest_pop_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Create `emquest/test/emquest_pop_SUITE.erl`:

```erlang
-module(emquest_pop_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([starts_successfully/1,
         peers_for_query_returns_empty_list_when_no_peers/1,
         peers_for_query_filters_out_no_query_port/1]).

all() ->
    [starts_successfully,
     peers_for_query_returns_empty_list_when_no_peers,
     peers_for_query_filters_out_no_query_port].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) -> ok.

%% emquest_pop starts an em_pop node and can be shut down cleanly.
starts_successfully(_Config) ->
    %% Use an unregistered start to avoid conflicting with a running Emquest.
    {ok, Pid} = gen_server:start_link(emquest_pop,
                                       #{pop_port => 19500, seeds => []},
                                       []),
    true = is_pid(Pid),
    gen_server:stop(Pid),
    ok.

%% When there are no peers, peers_for_query returns [].
peers_for_query_returns_empty_list_when_no_peers(_Config) ->
    {ok, Pid} = gen_server:start_link(emquest_pop,
                                       #{pop_port => 19501, seeds => []},
                                       []),
    Vec    = em_filter_vec:from_capabilities([<<"rss">>]),
    []     = gen_server:call(Pid, {peers_for_query, Vec, 5}),
    gen_server:stop(Pid),
    ok.

%% peers_for_query returns only peers that have a non-undefined query_port.
peers_for_query_filters_out_no_query_port(_Config) ->
    %% Start an emquest_pop instance.
    {ok, PopPid} = gen_server:start_link(emquest_pop,
                                          #{pop_port => 19502, seeds => []},
                                          []),
    Vec = em_filter_vec:from_capabilities([<<"rss">>]),

    %% Start a peer agent WITH a query_port and connect it to our pop node.
    {ok, AgentPid} = em_pop_node:start_link(#{
        port            => 19503,
        query_port      => 19504,
        vector          => Vec,
        gossip_interval => 0
    }),
    %% Manually inject the agent as a peer of our pop node.
    #{node := Node} = sys:get_state(PopPid),
    ok = em_pop_node:add_peer(Node, "127.0.0.1", 19503),

    %% peers_for_query must return the agent (has query_port).
    Results = gen_server:call(PopPid, {peers_for_query, Vec, 5}),
    1 = length(Results),
    {PeerMap, _Score} = hd(Results),
    19504 = maps:get(query_port, PeerMap),

    gen_server:stop(PopPid),
    exit(AgentPid, shutdown),
    ok.
```

- [ ] **Step 2: Run — expect failure**

```
cd emquest && rebar3 ct --suite emquest_pop_SUITE
```

Expected: `undef` for `emquest_pop`.

- [ ] **Step 3: Create `emquest/src/emquest_pop.erl`**

```erlang
%%%-------------------------------------------------------------------
%%% @doc
%%% emquest_pop — Emquest's Population Protocol node manager.
%%%
%%% Owns one `em_pop_node' gen_server on behalf of Emquest.  That node
%%% maintains a peer table of up to 5 000 em_filter agents, updated
%%% continuously by background gossip.  emquest_pop exposes a single
%%% public function, `peers_for_query/2', which the Emquest pipeline
%%% calls to obtain the K most semantically relevant agents for direct
%%% HTTP dispatch.
%%%
%%% === Startup ===
%%%
%%% The gen_server starts an em_pop_node listening on `pop_port'
%%% (from `[emquest] pop_port' in emergence.conf, default 9100).
%%% It then contacts each `{Host, PopPort}' from `queen:pop_seeds/0'
%%% to seed the peer table.  Bootstrap failures are caught — they do
%%% not abort startup.
%%%
%%% === Routing ===
%%%
%%% `peers_for_query(QueryVec, K)' performs:
%%%   1. kvex cosine search over the peer table for the top K*3 hits.
%%%   2. Filters to peers that advertise a `query_port' (non-undefined).
%%%   3. Returns at most K `{PeerMap, Score}' pairs.
%%%
%%% Peers without `query_port' are excluded because Emquest cannot
%%% reach them via direct HTTP — they remain reachable via the
%%% WebSocket bus (Phase 2 fallback path).
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(emquest_pop).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, peers_for_query/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Maximum number of peers this node maintains.
%% Larger than a regular agent so Emquest sees as much of the network
%% as possible for good routing coverage.
-define(MAX_PEERS, 5_000).

%% Capability label for Emquest's em_pop node.
-define(EMQUEST_CAPS, [<<"search">>]).

%%--------------------------------------------------------------------
%% @doc Start and globally register the Emquest em_pop manager.
%%
%% Call this once at application boot via `emquest_sup'.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

%%--------------------------------------------------------------------
%% @doc Return the top-K agents most similar to QueryVec that expose
%% a `query_port' for direct HTTP dispatch.
%%
%% Returns `[{PeerMap, Score}]' ordered by descending cosine similarity.
%% Returns `[]' when the peer table is empty (normal at startup before
%% the first gossip round completes).
%%
%% Peers without `query_port' are silently excluded — they can only be
%% reached via the em_disco WebSocket bus (Phase 2 fallback).
%% @end
%%--------------------------------------------------------------------
-spec peers_for_query(binary(), pos_integer()) ->
    [{map(), float()}].
peers_for_query(QueryVec, K) ->
    gen_server:call(?MODULE, {peers_for_query, QueryVec, K}, 15_000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    application:ensure_all_started(inets),
    Port  = maps:get(pop_port, Opts, queen:emquest_pop_port()),
    Vec   = em_filter_vec:from_capabilities(?EMQUEST_CAPS),
    Seeds = maps:get(seeds, Opts, queen:pop_seeds()),
    NodeOpts = #{port            => Port,
                 vector          => Vec,
                 max_peers       => ?MAX_PEERS,
                 gossip_interval => 5_000},
    case em_pop_node:start_link(NodeOpts) of
        {ok, NodePid} ->
            %% Seed the peer table; individual failures are non-fatal.
            lists:foreach(fun({H, P}) ->
                catch em_pop_node:add_peer(NodePid, H, P)
            end, Seeds),
            ?LOG_INFO("[emquest_pop] started on port ~w, ~w seed(s)",
                      [Port, length(Seeds)]),
            {ok, #{node => NodePid}};
        {error, Reason} ->
            {stop, {em_pop_node_start_failed, Reason}}
    end.

handle_call({peers_for_query, QueryVec, K}, _From,
            #{node := Node} = State) ->
    %% Request more candidates than K so filtering doesn't exhaust the list.
    Candidates = em_pop_node:peers_for(Node, QueryVec, K * 3),
    %% Keep only peers with a non-undefined query_port.
    Routable = [{PeerMap, Score}
                || {PeerMap, Score} <- Candidates,
                   maps:get(query_port, PeerMap, undefined) =/= undefined],
    {reply, lists:sublist(Routable, K), State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
```

- [ ] **Step 4: Run tests — expect pass**

```
cd emquest && rebar3 ct --suite emquest_pop_SUITE
```

Expected: All 3 tests green.

> Note: `peers_for_query_filters_out_no_query_port` uses `sys:get_state/1` to reach into the gen_server internals. This is acceptable in test code.

- [ ] **Step 5: Commit**

```bash
cd emquest
git add src/emquest_pop.erl test/emquest_pop_SUITE.erl
git commit -m "feat(emquest): add emquest_pop gen_server — Phase 2b em_pop node lifecycle"
```

---

### Task 10: Wire `emquest_pop` into `emquest_sup`

**Files:**
- Modify: `emquest/src/emquest_sup.erl`

- [ ] **Step 1: Add `emquest_pop` as a supervised child**

Replace:
```erlang
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
```
With:
```erlang
    PopChild = #{
        id       => emquest_pop,
        start    => {emquest_pop, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [emquest_pop]
    },
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [PopChild]}}.
```

- [ ] **Step 2: Compile and verify**

```
cd emquest && rebar3 compile
```

Expected: clean.

- [ ] **Step 3: Quick smoke test — start the shell**

```
cd emquest && rebar3 shell
```

Then in the Erlang shell:
```erlang
emquest_pop:peers_for_query(em_filter_vec:from_capabilities([<<"rss">>]), 5).
```

Expected: `[]` (empty — no peers yet since no em_filter agents are running). No crash.

Exit with `q().`.

- [ ] **Step 4: Commit**

```bash
cd emquest
git add src/emquest_sup.erl
git commit -m "feat(emquest_sup): start emquest_pop as a supervised child at boot"
```

---

### Task 11: Parallel dispatch in `emquest_handler`

**Files:**
- Modify: `emquest/src/emquest_handler.erl`

This is the core Phase 2b change. `run_pipeline/2` adds an em_pop fan-out alongside the existing disco fan-out. Both dispatch into the same `{disco_result, ...}` message pattern so `collect_disco_streaming/4` collects both without changes.

- [ ] **Step 1: Write the failing test**

Create `emquest/test/emquest_handler_SUITE.erl`:

```erlang
-module(emquest_handler_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([fetch_from_agent_returns_items/1,
         fetch_from_agent_bad_response_returns_error/1]).

all() ->
    [fetch_from_agent_returns_items,
     fetch_from_agent_bad_response_returns_error].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) -> ok.

%% fetch_from_agent/2 parses a {"results": [...]} response correctly.
fetch_from_agent_returns_items(_Config) ->
    %% Start a mock Cowboy listener that returns a known payload.
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", mock_agent_handler,
                #{results => [#{<<"url">> => <<"http://example.com">>}]}}]}
    ]),
    {ok, _} = cowboy:start_clear(mock_agent_listener,
                                  [{port, 19600}],
                                  #{env => #{dispatch => Dispatch}}),
    Body = iolist_to_binary(json:encode(#{<<"query">> => <<"test">>})),
    {ok, Items} = emquest_handler:fetch_from_agent(
                      Body, "http://localhost:19600/agent/query"),
    true = is_list(Items),
    true = length(Items) > 0,
    cowboy:stop_listener(mock_agent_listener),
    ok.

%% An unreachable agent returns {error, _}.
fetch_from_agent_bad_response_returns_error(_Config) ->
    Body = iolist_to_binary(json:encode(#{<<"query">> => <<"test">>})),
    {error, _} = emquest_handler:fetch_from_agent(
                     Body, "http://localhost:1/agent/query"),
    ok.
```

Also create the mock handler `emquest/test/mock_agent_handler.erl`:

```erlang
-module(mock_agent_handler).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, #{results := Results} = State) ->
    Body = iolist_to_binary(json:encode(#{<<"results">> => Results})),
    Req  = cowboy_req:reply(200,
               #{<<"content-type">> => <<"application/json">>},
               Body, Req0),
    {ok, Req, State}.
```

- [ ] **Step 2: Run — expect failure**

```
cd emquest && rebar3 ct --suite emquest_handler_SUITE
```

Expected: `undef` for `emquest_handler:fetch_from_agent/2`.

- [ ] **Step 3: Add `fetch_from_agent/2` and `spawn_pop_workers/3` to `emquest_handler.erl`**

Add at the end of the Disco HTTP section (after `fetch_from_disco/2`):

```erlang
%%--------------------------------------------------------------------
%% @doc POST a query directly to one em_pop agent and return its items.
%%
%% `Url' is the full endpoint, e.g. `"http://agent.lan:9201/agent/query"'.
%% Returns `{ok, [Item]}' on success — Items are the decoded results
%% from the agent's `{"results": [...]}' response body.
%%
%% Returns `{error, Reason}' on any HTTP error, timeout, or bad JSON.
%% @end
%%--------------------------------------------------------------------
-spec fetch_from_agent(binary(), string()) ->
    {ok, [map()]} | {error, term()}.
fetch_from_agent(Body, Url) ->
    case httpc:request(post,
                       {Url, [], "application/json",
                        binary_to_list(Body)},
                       [{timeout, 8000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try
                #{<<"results">> := Items} = json:decode(RespBody),
                case is_list(Items) of
                    true  -> {ok, Items};
                    false -> {ok, []}
                end
            catch _:_ -> {error, invalid_response} end;
        {ok, {{_, Code, _}, _, _}} -> {error, {http, Code}};
        {error, R}                 -> {error, R}
    end.

%%--------------------------------------------------------------------
%% @doc Spawn one worker process per (sub-query × em_pop peer).
%%
%% Workers send `{disco_result, self(), Tag, Items}' to Parent —
%% the same message pattern as disco workers so `collect_disco_streaming'
%% handles both sources transparently.
%%
%% `Peers' is the list returned by `emquest_pop:peers_for_query/2':
%%   `[{#{host := H, query_port := QP, ...}, Score}]'.
%% @end
%%--------------------------------------------------------------------
-spec spawn_pop_workers([binary()], [{map(), float()}], pid()) -> [pid()].
spawn_pop_workers(SubQueries, Peers, Parent) ->
    [spawn(fun() ->
        H   = binary_to_list(maps:get(host, PeerMap)),
        QP  = maps:get(query_port, PeerMap),
        Url = lists:flatten(
                  io_lib:format("http://~s:~w/agent/query", [H, QP])),
        Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
        Tag  = iolist_to_binary([Q, " @pop ", H, ":", integer_to_list(QP)]),
        case fetch_from_agent(Body, Url) of
            {ok, Items} ->
                Parent ! {disco_result, self(), Tag, Items};
            {error, R} ->
                logger:warning("[emquest] pop agent fail ~s: ~p", [Tag, R]),
                Parent ! {disco_result, self(), Tag, []}
        end
    end)
    || Q <- SubQueries, {PeerMap, _Score} <- Peers].
```

- [ ] **Step 4: Update `run_pipeline/2` to include em_pop dispatch**

Replace the current `run_pipeline/2`:

```erlang
-spec run_pipeline(binary(), cowboy_req:req()) -> ok.
run_pipeline(Query, Req) ->
    logger:notice("[emquest] query: ~ts", [Query]),
    %% Step 1 — expand query into sub-queries
    sse(Req, status, <<"Expanding query...">>),
    SubQueries = queen:expand(Query),

    %% Step 2 — discover all disco nodes (local + registry)
    Nodes = queen:disco_nodes(),
    sse(Req, status, iolist_to_binary([
        "Querying ", integer_to_binary(length(Nodes)), " disco node(s) with ",
        integer_to_binary(length(SubQueries)), " sub-query(ies)..."
    ])),

    %% Step 3 — cartesian fan-out: one spawn per (sub-query × disco node).
    %% All processes run in parallel regardless of how many nodes there are.
    %% Disco URLs are read once here so spawned closures reuse them.
    Parent = self(),
    DiscoUrls = [Node ++ "/query" || Node <- Nodes],
    Pids = [spawn(fun() ->
                Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                Tag  = iolist_to_binary([Q, " @ ", Url]),
                case fetch_from_disco(Body, Url) of
                    {ok, #{<<"embryo_list">> := Items}} ->
                        Parent ! {disco_result, self(), Tag, Items};
                    {error, R} ->
                        logger:warning("[emquest] disco fail ~s: ~p", [Tag, R]),
                        Parent ! {disco_result, self(), Tag, []}
                end
             end) || Q <- SubQueries, Url <- DiscoUrls],

    %% Collect results, streaming each item immediately as it arrives.
    TaggedItems = collect_disco_streaming(length(Pids), Req, [], 0),

    %% Step 4 — deduplicate by URL (first occurrence wins)
    DedupedTagged = deduplicate_tagged(TaggedItems),

    logger:notice("[emquest] ~p response(s) collected", [length(DedupedTagged)]),

    %% Step 5 — send reorder to deduplicate browser-side (arrival order, no LLM ranking)
    AllSids = [S || {S, _} <- DedupedTagged],
    NeutralScores = maps:from_list([{integer_to_binary(S), 0} || S <- AllSids]),
    sse_reorder(Req, AllSids, NeutralScores),

    cowboy_req:stream_body(<<>>, fin, Req).
```

With:

```erlang
-spec run_pipeline(binary(), cowboy_req:req()) -> ok.
run_pipeline(Query, Req) ->
    logger:notice("[emquest] query: ~ts", [Query]),

    %% Step 1 — expand query into sub-queries.
    sse(Req, status, <<"Expanding query...">>),
    SubQueries = queen:expand(Query),

    %% Step 2 — disco fan-out: one process per (sub-query × disco node).
    Nodes     = queen:disco_nodes(),
    DiscoUrls = [Node ++ "/query" || Node <- Nodes],
    Parent    = self(),
    DiscoPids = [spawn(fun() ->
                    Body = iolist_to_binary(json:encode(#{<<"query">> => Q})),
                    Tag  = iolist_to_binary([Q, " @ ", Url]),
                    case fetch_from_disco(Body, Url) of
                        {ok, #{<<"embryo_list">> := Items}} ->
                            Parent ! {disco_result, self(), Tag, Items};
                        {error, R} ->
                            logger:warning("[emquest] disco fail ~s: ~p",
                                           [Tag, R]),
                            Parent ! {disco_result, self(), Tag, []}
                    end
                 end) || Q <- SubQueries, Url <- DiscoUrls],

    %% Step 3 — em_pop fan-out: query vector → top-K peers → direct HTTP.
    %% Runs in parallel with the disco fan-out above.
    QueryVec = em_filter_vec:from_capabilities(SubQueries),
    PopPeers = try emquest_pop:peers_for_query(QueryVec, 10)
               catch _:_ -> []   %% emquest_pop not running (CLI mode)
               end,
    PopPids  = spawn_pop_workers(SubQueries, PopPeers, Parent),

    %% Report how many sources we are waiting on.
    TotalWorkers = length(DiscoPids) + length(PopPids),
    sse(Req, status, iolist_to_binary([
        "Querying ", integer_to_binary(length(DiscoUrls)),
        " disco + ", integer_to_binary(length(PopPeers)),
        " em_pop peer(s)..."
    ])),

    %% Step 4 — collect all results (disco + em_pop), streaming each item.
    TaggedItems = collect_disco_streaming(TotalWorkers, Req, [], 0),

    %% Step 5 — deduplicate by URL (first occurrence wins).
    DedupedTagged = deduplicate_tagged(TaggedItems),

    logger:notice("[emquest] ~p response(s) collected (~p workers)",
                  [length(DedupedTagged), TotalWorkers]),

    %% Step 6 — send reorder event so the browser reconciles arrival order.
    AllSids       = [S || {S, _} <- DedupedTagged],
    NeutralScores = maps:from_list(
                        [{integer_to_binary(S), 0} || S <- AllSids]),
    sse_reorder(Req, AllSids, NeutralScores),

    cowboy_req:stream_body(<<>>, fin, Req).
```

Also export `fetch_from_agent/2` — add it to the module's export list. Currently:
```erlang
-export([init/2]).
```
Replace with:
```erlang
-export([init/2, fetch_from_agent/2]).
```

- [ ] **Step 5: Run tests**

```
cd emquest && rebar3 ct --suite emquest_handler_SUITE
```

Expected: Both tests pass.

- [ ] **Step 6: Run the full Emquest test suite**

```
cd emquest && rebar3 ct
```

Expected: all suites pass (queen_pop_seeds_SUITE, emquest_pop_SUITE, emquest_handler_SUITE).

- [ ] **Step 7: Commit**

```bash
cd emquest
git add src/emquest_handler.erl \
        test/emquest_handler_SUITE.erl \
        test/mock_agent_handler.erl
git commit -m "feat(emquest): parallel em_pop dispatch alongside disco — Phase 2b"
```

---

### Task 12: Update `emquest.app.src`

**Files:**
- Modify: `emquest/src/emquest.app.src`

- [ ] **Step 1: Bump version, add kvex to applications, list new modules**

Replace the full content with:

```erlang
{application, emquest, [
    {description, "Client Emquest — semantic search dispatcher"},
    {vsn, "0.2.0"},
    {registered, [emquest_pop]},
    {mod, {emquest_app, []}},
    {applications, [
        kernel,
        stdlib,
        inets,
        cowboy,
        kvex
    ]},
    {env, []},
    {modules, [
        emquest_app,
        emquest_sup,
        emquest_handler,
        emquest_pop,
        emquest_cli,
        queen,
        em_filter_vec,
        em_pop_node,
        em_pop_http
    ]},
    {licenses, ["Apache 2.0"]},
    {links, [{"GitHub", "https://github.com/EmergenceSystem/Emquest"}]}
]}.
```

- [ ] **Step 2: Compile and verify**

```
cd emquest && rebar3 compile
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd emquest
git add src/emquest.app.src
git commit -m "chore(emquest): bump vsn to 0.2.0, register emquest_pop, add kvex"
```

---

## Verification Checklist

After all tasks complete, run these end-to-end checks:

- [ ] **em_filter full suite**:
  ```
  cd filters/em_filter && rebar3 ct
  ```
  Expected: all suites green.

- [ ] **Emquest full suite**:
  ```
  cd emquest && rebar3 ct
  ```
  Expected: all suites green.

- [ ] **Manual integration smoke test** (requires two terminals):

  Terminal 1 — start a test agent with query_port:
  ```bash
  cd filters/em_filter
  rebar3 shell
  ```
  ```erlang
  % In the shell:
  em_filter_sup:start_link().
  em_filter_sup:start_agent(my_agent, echo_handler, #{
      disco_nodes  => [{"localhost", 8080, tcp}],
      query_port   => 9201,
      pop_port     => 9200,
      capabilities => [<<"rss">>, <<"python">>]
  }).
  ```

  Terminal 2 — verify direct HTTP query works:
  ```bash
  curl -s -X POST http://localhost:9201/agent/query \
       -H "Content-Type: application/json" \
       -d '{"query": "python rss news"}'
  ```
  Expected: `{"results":[{"echo":"python rss news"}]}`

  Also verify gossip payload includes query_port:
  ```bash
  curl -s -X POST http://localhost:9200/pop/gossip \
       -H "Content-Type: application/json" \
       -d "{\"id\":\"$(openssl rand -base64 16)\",\"host\":\"127.0.0.1\",\"port\":9999,\"query_port\":null,\"vector\":\"$(python3 -c 'import struct,base64; print(base64.b64encode(struct.pack("<64f", *([0.125]*64))).decode())')\",\"peers\":[]}"
  ```
  Expected: JSON response containing `"query_port":9201`.

---

## Configuration Reference (for operators)

Add to `emergence.conf` for each agent that should be reachable by direct em_pop dispatch:

```ini
[em_disco]
nodes    = disco.mynetwork.com:8080   ; WebSocket bus (Phase 1/2)
pop_port = 9000                       ; em_pop gossip seed port (Phase 2)

[emquest]
pop_port = 9100                       ; Emquest's own em_pop listener (default 9100)
```

Per-agent config (in Erlang startup code):

```erlang
em_filter_sup:start_agent(my_agent, my_handler, #{
    pop_port     => 9200,     %% em_pop gossip listener for this agent
    query_port   => 9201,     %% direct HTTP query endpoint
    capabilities => [<<"rss">>, <<"python">>]
}).
```
