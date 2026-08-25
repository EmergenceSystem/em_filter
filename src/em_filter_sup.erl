%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter Top-Level Supervisor
%%%
%%% Manages the em_filter_server worker pool and the em_pop Population
%%% Protocol sub-supervisor.
%%%
%%% Strategy: `one_for_one'.
%%%   • em_pop_sup  — permanent child, started at application boot.
%%%   • em_filter_server workers — added dynamically via start_agent/3,
%%%     each with its own unique child id.
%%%
%%% When `start_agent/3' is called, one em_filter_server worker is
%%% started per configured disco node.  If the Config map contains a
%%% `pop_port' key, an em_pop Population Protocol node is also started
%%% and registered in em_pop_sup's ETS registry.
%%%
%%% === Node format in emergence.conf ===
%%%
%%%   nodes = localhost:8080, disco.example.com
%%%
%%% Port resolution (when no port is given):
%%%   localhost / 127.0.0.1  → 8080, plain TCP
%%%   any other host         → 443,  TLS
%%%
%%% Explicit port always wins:
%%%   localhost:9000         → 9000, plain TCP
%%%   example.com:8080       → 8080, plain TCP
%%%   example.com:443        → 443,  TLS
%%%
%%% === em_pop Config keys ===
%%%
%%%   pop_port            => pos_integer()   — required to enable em_pop
%%%   pop_peers           => [{Host, Port}]  — bootstrap peers + auto-repair seeds (optional)
%%%   pop_stale_timeout   => pos_integer()   — default 30 000 ms
%%%   pop_gossip_interval => pos_integer()   — default  5 000 ms (0=off)
%%%   pop_max_peers       => pos_integer()   — default 200
%%%   pop_persist_dir     => string()        — DETS directory; absent = no persistence
%%%   pop_evict_threshold => float()         — trust floor for immediate eviction; default 0.0
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_sup).
-behaviour(supervisor).

-export([start_link/0, start_agent/3, stop_agent/1, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc Starts one worker per configured disco node for the agent.
%%
%% Node list is taken from (in priority order):
%%   1. `disco_nodes' key in Config map (useful for testing)
%%   2. EM_DISCO_HOST / EM_DISCO_PORT environment variables
%%   3. `[em_disco] nodes = ...' in emergence.conf
%%   4. Default: [{"localhost", 8080, tcp}]
%%
%% If Config contains `pop_port', an em_pop node is also started and
%% the capability vector is derived from the `capabilities' list.
%%
%% Returns `{ok, Pid}' of the first successfully started worker.
%%
%% @param AgentName     Unique atom identifying the agent.
%% @param HandlerModule Module exporting handle/2.
%% @param Config        Agent options map.
%% @end
%%--------------------------------------------------------------------
-spec start_agent(atom(), module(), map()) ->
    {ok, pid()} | {error, term()}.
start_agent(AgentName, HandlerModule, Config) ->
    Nodes        = resolve_nodes(Config),
    IndexedNodes = lists:zip(lists:seq(1, length(Nodes)), Nodes),
    Results      = lists:map(fun({Idx, Node}) ->
        ChildId   = {em_filter_server, AgentName, Idx},
        ChildSpec = #{
            id       => ChildId,
            start    => {em_filter_server, start_link,
                         [AgentName, HandlerModule, Config, Node, Idx]},
            restart  => transient,
            shutdown => 5000,
            type     => worker,
            modules  => [em_filter_server]
        },
        supervisor:start_child(?MODULE, ChildSpec)
    end, IndexedNodes),
    _ = maybe_start_pop_node(AgentName, Config),
    _ = maybe_start_query_listener(AgentName, Config),
    first_ok(Results).

%%--------------------------------------------------------------------
%% @doc Stops all workers and the em_pop node for the given agent.
%%
%% Returns `{error, not_running}' if no matching worker is found.
%% @end
%%--------------------------------------------------------------------
-spec stop_agent(atom()) -> ok | {error, not_running}.
stop_agent(AgentName) ->
    Prefix   = atom_to_list(AgentName) ++ "_server",
    Children = supervisor:which_children(?MODULE),
    Matching = lists:filtermap(fun({ChildId, Pid, _, _}) ->
        case Pid of
            P when is_pid(P) ->
                case process_info(P, registered_name) of
                    {registered_name, Name} ->
                        case is_agent_server(atom_to_list(Name), Prefix) of
                            true  -> {true, ChildId};
                            false -> false
                        end;
                    _ -> false
                end;
            _ -> false
        end
    end, Children),
    case Matching of
        [] ->
            {error, not_running};
        Ids ->
            lists:foreach(fun(Id) ->
                supervisor:terminate_child(?MODULE, Id),
                supervisor:delete_child(?MODULE, Id)
            end, Ids),
            em_pop_sup:stop_node(AgentName),
            catch cowboy:stop_listener({em_filter_query, AgentName}),
            ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Supervisor init — one_for_one with em_pop_sup as permanent child.
%%
%% em_pop_sup is always started at boot so its ETS registry is ready
%% before any `start_agent/3' call arrives.
%%
%% em_filter_server workers are added dynamically by `start_agent/3'
%% using full child specs (required by the one_for_one strategy).
%% They are not listed here.
%% @end
%%--------------------------------------------------------------------
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    PopSup = #{
        id       => em_pop_sup,
        start    => {em_pop_sup, start_link, []},
        restart  => permanent,         %% always restart if it crashes
        shutdown => 5000,
        type     => supervisor,
        modules  => [em_pop_sup]
    },
    {ok, {#{strategy  => one_for_one,
            intensity => 10,           %% max 10 restarts …
            period    => 60},          %% … in any 60-second window
          [PopSup]}}.                  %% workers added dynamically

%%====================================================================
%% em_pop integration
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Optionally start an em_pop Population Protocol node for an agent.
%%
%% Only starts a node when the Config map contains a `pop_port' key.
%% Agents without `pop_port' continue to work exactly as before — this
%% function is a no-op for them (graceful degradation).
%%
%% Steps when `pop_port' is present:
%%   1. Derive a semantic capability vector from the `capabilities'
%%      list using `em_filter_vec:from_capabilities/1'.  The vector is
%%      deterministic: same capabilities always produce the same vector.
%%   2. Start an em_pop_node via em_pop_sup, which also registers it in
%%      the ETS table under AgentName.
%%   3. Contact each `pop_peers' bootstrap peer (if any) to seed the
%%      peer table and trigger the first gossip exchange.
%%
%% Bootstrap failures are caught and logged — they do not prevent the
%% agent from starting.
%% @end
%%--------------------------------------------------------------------
-spec maybe_start_pop_node(atom(), map()) -> ok | {ok, pid()}.
maybe_start_pop_node(AgentName, Config) ->
    case maps:get(pop_port, Config, undefined) of
        undefined ->
            %% No pop_port — em_pop is not enabled for this agent.
            ok;
        Port ->
            %% Derive the capability vector from the agent's capabilities.
            Caps  = maps:get(capabilities, Config, []),
            Vec   = em_filter_vec:from_capabilities(Caps),
            Seeds = maps:get(pop_peers, Config, []),  %% dual role: bootstrap + repair seeds

            PopOpts = #{
                port            => Port,
                advertise_host  => maps:get(pop_advertise_host, Config, <<"localhost">>),
                name            => atom_to_binary(AgentName, utf8),
                vector          => Vec,
                seeds           => Seeds,
                evict_threshold => maps:get(pop_evict_threshold, Config, 0.0),
                persist_dir     => maps:get(pop_persist_dir,     Config, undefined),
                stale_timeout   => maps:get(pop_stale_timeout,   Config, 30_000),
                gossip_interval => maps:get(pop_gossip_interval, Config,  5_000),
                max_peers       => maps:get(pop_max_peers,        Config,    200)
            },
            case em_pop_sup:start_node(AgentName, PopOpts) of
                {ok, Pid} ->
                    %% Bootstrap: contact each seed immediately on startup.
                    %% Errors are caught so a dead bootstrap does not
                    %% prevent the agent from starting.
                    lists:foreach(fun({H, P}) ->
                        catch em_pop_node:add_peer(Pid, H, P)
                    end, Seeds),
                    {ok, Pid};
                Error ->
                    logger:warning("[em_filter] em_pop start failed",
                                   #{agent => AgentName, error => Error}),
                    ok
            end
    end.

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

%%====================================================================
%% Disco node resolution
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Returns `disco_nodes' from Config if present, otherwise reads
%% from environment variables and emergence.conf.
%% @end
%%--------------------------------------------------------------------
-spec resolve_nodes(map()) ->
    [{string(), inet:port_number(), tcp | tls}].
resolve_nodes(Config) ->
    case maps:get(disco_nodes, Config, undefined) of
        Nodes when is_list(Nodes), Nodes =/= [] -> Nodes;
        _ -> read_disco_nodes()
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Returns the list of disco nodes as {Host, Port, Transport}.
%%
%% Priority order:
%%   1. EM_DISCO_HOST / EM_DISCO_PORT env vars
%%   2. [em_disco] nodes = ... in emergence.conf
%%   3. Default: [{"localhost", 8080, tcp}]
%% @end
%%--------------------------------------------------------------------
-spec read_disco_nodes() -> [{string(), inet:port_number(), tcp | tls}].
read_disco_nodes() ->
    case {os:getenv("EM_DISCO_HOST"), os:getenv("EM_DISCO_PORT")} of
        {false, false} ->
            case conf_nodes() of
                []    -> [{"localhost", 8080, tcp}];
                Nodes -> Nodes
            end;
        {Host, false} ->
            H = case Host of false -> "localhost"; H0 -> H0 end,
            {Port, Transport} = default_port_transport(H, undefined),
            [{H, Port, Transport}];
        {false, Port} ->
            P = list_to_integer(Port),
            [{"localhost", P, port_transport("localhost", P)}];
        {Host, Port} ->
            P = list_to_integer(Port),
            [{Host, P, port_transport(Host, P)}]
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Parses the nodes key from [em_disco] in emergence.conf.
%% @end
%%--------------------------------------------------------------------
-spec conf_nodes() -> [{string(), inet:port_number(), tcp | tls}].
conf_nodes() ->
    case read_conf() of
        undefined -> [];
        Map ->
            Section = maps:get("em_disco", Map, #{}),
            case maps:get("nodes", Section, undefined) of
                undefined ->
                    Host = maps:get("host", Section, "localhost"),
                    Port = list_to_integer(
                               maps:get("port", Section, "8080")),
                    [{Host, Port, port_transport(Host, Port)}];
                NodesStr ->
                    parse_nodes(NodesStr)
            end
    end.

%% @private
-spec parse_nodes(string()) -> [{string(), inet:port_number(), tcp | tls}].
parse_nodes(Str) ->
    Entries = string:split(Str, ",", all),
    lists:filtermap(fun(Entry) ->
        case string:trim(Entry) of
            "" -> false;
            E  ->
                case string:split(E, ":", trailing) of
                    [Host, PortStr] ->
                        H = string:trim(Host),
                        try
                            P = list_to_integer(string:trim(PortStr)),
                            {true, {H, P, port_transport(H, P)}}
                        catch _:_ -> false end;
                    [Host] ->
                        H = string:trim(Host),
                        {Port, Transport} = default_port_transport(H, undefined),
                        {true, {H, Port, Transport}};
                    _ ->
                        false
                end
        end
    end, Entries).

%% @private
-spec default_port_transport(string(), undefined) ->
    {inet:port_number(), tcp | tls}.
default_port_transport("localhost",  _) -> {8080, tcp};
default_port_transport("127.0.0.1", _) -> {8080, tcp};
default_port_transport(_Host,       _) -> {443,  tls}.

%% @private
-spec port_transport(string(), inet:port_number()) -> tcp | tls.
port_transport("localhost",  _)   -> tcp;
port_transport("127.0.0.1", _)   -> tcp;
port_transport(_Host,       443)  -> tls;
port_transport(_Host,       _)    -> tcp.

%%====================================================================
%% Config helpers
%%====================================================================

%% @private
-spec read_conf() -> map() | undefined.
read_conf() ->
    case conf_path() of
        undefined -> undefined;
        Path ->
            case file:read_file(Path) of
                {ok, Bin} -> parse_conf(Bin);
                _         -> undefined
            end
    end.

%% @private
-spec conf_path() -> string() | undefined.
conf_path() ->
    case {os:getenv("HOME"), os:getenv("APPDATA"), os:type()} of
        {false, false, _}    -> undefined;
        {false, AppData, _}  ->
            filename:join([AppData, "emergence", "emergence.conf"]);
        {Home, _, {unix, _}} ->
            filename:join([Home, ".config", "emergence", "emergence.conf"]);
        {Home, _, _}         ->
            filename:join([Home, "AppData", "Roaming", "emergence",
                           "emergence.conf"])
    end.

%% @private
-spec parse_conf(binary()) -> map().
parse_conf(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    {Map, _} = lists:foldl(fun parse_line/2, {#{}, ""}, Lines),
    Map.

%% @private
parse_line(<<";", _/binary>>, Acc) -> Acc;
parse_line(<<"#", _/binary>>, Acc) -> Acc;
parse_line(<<"[", Rest/binary>>, {Map, _Sec}) ->
    Sec = string:trim(binary_to_list(Rest), both, "]\r\n "),
    {Map#{Sec => #{}}, Sec};
parse_line(Line, {Map, Sec}) when Sec =/= "" ->
    case binary:split(Line, <<"=">>) of
        [K, V] ->
            Key = string:trim(binary_to_list(K)),
            Val = string:trim(binary_to_list(V)),
            {Map#{Sec => maps:put(Key, Val, maps:get(Sec, Map, #{}))}, Sec};
        _ -> {Map, Sec}
    end;
parse_line(_, Acc) -> Acc.

%%====================================================================
%% Private helpers
%%====================================================================

%% @private
-spec first_ok([{ok, pid()} | {error, term()}]) ->
    {ok, pid()} | {error, term()}.
first_ok([]) ->
    {error, no_nodes};
first_ok([{ok, Pid} | _]) ->
    {ok, Pid};
first_ok([{error, _} = Err | Rest]) ->
    case first_ok(Rest) of
        {error, _} -> Err;
        Ok         -> Ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Returns true if NameStr matches the `<agent>_server' pattern.
%%
%% Matches exactly `<agent>_server' or has prefix `<agent>_server_'
%% (for multi-node workers `<agent>_server_2', `<agent>_server_3').
%% @end
%%--------------------------------------------------------------------
-spec is_agent_server(string(), string()) -> boolean().
is_agent_server(NameStr, Prefix) ->
    NameStr =:= Prefix
    orelse lists:prefix(Prefix ++ "_", NameStr).
