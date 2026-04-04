%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter Top-Level Supervisor
%%%
%%% Manages a dynamic pool of `em_filter_server' workers using a
%%% `simple_one_for_one' strategy.
%%%
%%% When `start_agent/3' is called, one worker is started per
%%% configured disco node. An agent automatically connects to every
%%% node listed in the `disco_nodes' agent config key or discovered
%%% via environment variables and emergence.conf.
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
%% Returns `{ok, Pid}' of the first successfully started worker.
%%
%% @param AgentName     Unique atom identifying the agent.
%% @param HandlerModule Module exporting handle/2.
%% @param Config        Agent options map (capabilities, memory,
%%                      jwt_token, disco_nodes).
%% @end
%%--------------------------------------------------------------------
-spec start_agent(atom(), module(), map()) ->
    {ok, pid()} | {error, term()}.
start_agent(AgentName, HandlerModule, Config) ->
    Nodes        = resolve_nodes(Config),
    IndexedNodes = lists:zip(lists:seq(1, length(Nodes)), Nodes),
    Results      = lists:map(fun({Idx, Node}) ->
        supervisor:start_child(?MODULE,
                               [AgentName, HandlerModule, Config, Node, Idx])
    end, IndexedNodes),
    first_ok(Results).

%%--------------------------------------------------------------------
%% @doc Stops all workers for the given agent name.
%%
%% Returns `{error, not_running}' if no matching worker is found.
%% @end
%%--------------------------------------------------------------------
-spec stop_agent(atom()) -> ok | {error, not_running}.
stop_agent(AgentName) ->
    Prefix   = atom_to_list(AgentName) ++ "_server",
    Children = supervisor:which_children(?MODULE),
    Matching = lists:filtermap(fun({_, Pid, _, _}) ->
        case Pid of
            P when is_pid(P) ->
                case process_info(P, registered_name) of
                    {registered_name, Name} ->
                        case is_agent_server(atom_to_list(Name), Prefix) of
                            true  -> {true, P};
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
        Pids ->
            lists:foreach(fun(P) ->
                supervisor:terminate_child(?MODULE, P)
            end, Pids),
            ok
    end.

%% @private
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Child = #{
        id       => em_filter_server,
        start    => {em_filter_server, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [em_filter_server]
    },
    {ok, {#{strategy  => simple_one_for_one,
            intensity => 10,
            period    => 60},
          [Child]}}.

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
