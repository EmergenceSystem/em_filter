%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter Top-Level Supervisor
%%%
%%% Manages a dynamic pool of `em_filter_server' workers using a
%%% `simple_one_for_one' strategy.
%%%
%%% When start_agent/3 is called, one worker is started PER configured
%%% disco node. This means an agent automatically connects to every
%%% disco node listed in emergence.conf [em_disco] nodes.
%%%
%%% Example — nodes = localhost:8080, em_disco.roques.me:8080
%%%   start_agent(my_filter, my_module, Config)
%%%   → spawns my_filter_localhost_8080_server
%%%   → spawns my_filter_em_disco_roques_me_8080_server
%%%
%%% Both workers share the same handler module and config, but each
%%% maintains its own WebSocket connection and memory independently.
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
%% Reads the disco node list from emergence.conf (or env vars).
%% Falls back to a single localhost:8080 worker if nothing is configured.
%%
%% @param AgentName     Unique atom identifying the agent.
%% @param HandlerModule Module exporting `handle/2'.
%% @param Config        Agent options map (capabilities, memory).
%% @end
%%--------------------------------------------------------------------
-spec start_agent(atom(), module(), map()) ->
    [{ok, pid()} | {error, term()}].
start_agent(AgentName, HandlerModule, Config) ->
    Nodes = read_disco_nodes(),
    lists:map(fun(Node) ->
        supervisor:start_child(?MODULE,
                               [AgentName, HandlerModule, Config, Node])
    end, Nodes).

%%--------------------------------------------------------------------
%% @doc Stops all workers for the given agent name.
%% @end
%%--------------------------------------------------------------------
-spec stop_agent(atom()) -> ok.
stop_agent(AgentName) ->
    Prefix = atom_to_list(AgentName) ++ "_",
    lists:foreach(fun({_, Pid, _, _}) ->
        case Pid of
            P when is_pid(P) ->
                Info = process_info(P, registered_name),
                case Info of
                    {registered_name, Name} ->
                        case lists:prefix(Prefix, atom_to_list(Name)) of
                            true  -> supervisor:terminate_child(?MODULE, P);
                            false -> ok
                        end;
                    _ -> ok
                end;
            _ -> ok
        end
    end, supervisor:which_children(?MODULE)).

%% @private
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
%% @doc Returns the list of disco nodes to connect to.
%%
%% Priority order:
%%   1. EM_DISCO_HOST / EM_DISCO_PORT env vars (single node, legacy)
%%   2. [em_disco] nodes = host:port, host:port in emergence.conf
%%   3. Default: [{"localhost", 8080}]
%% @end
%%--------------------------------------------------------------------
-spec read_disco_nodes() -> [{string(), inet:port_number()}].
read_disco_nodes() ->
    %% Legacy single-node env vars take priority for backwards compat.
    case {os:getenv("EM_DISCO_HOST"), os:getenv("EM_DISCO_PORT")} of
        {false, false} ->
            %% Read nodes list from emergence.conf.
            case conf_nodes() of
                []    -> [{"localhost", 8080}];
                Nodes -> Nodes
            end;
        {Host, false} ->
            [{case Host of false -> "localhost"; H -> H end, 8080}];
        {false, Port} ->
            [{"localhost", list_to_integer(Port)}];
        {Host, Port} ->
            [{Host, list_to_integer(Port)}]
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Parses the `nodes' key from [em_disco] in emergence.conf.
%%
%% Format: nodes = localhost:8080, em_disco.roques.me:8080
%% @end
%%--------------------------------------------------------------------
-spec conf_nodes() -> [{string(), inet:port_number()}].
conf_nodes() ->
    case read_conf() of
        undefined -> [];
        Map ->
            Section = maps:get("em_disco", Map, #{}),
            case maps:get("nodes", Section, undefined) of
                undefined ->
                    %% Fall back to legacy host + port keys.
                    Host = maps:get("host", Section, "localhost"),
                    Port = list_to_integer(
                               maps:get("port", Section, "8080")),
                    [{Host, Port}];
                NodesStr ->
                    parse_nodes(NodesStr)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Parses "host:port, host:port" into [{Host, Port}].
%% @end
%%--------------------------------------------------------------------
-spec parse_nodes(string()) -> [{string(), inet:port_number()}].
parse_nodes(Str) ->
    Entries = string:split(Str, ",", all),
    lists:filtermap(fun(Entry) ->
        case string:split(string:trim(Entry), ":", trailing) of
            [Host, PortStr] ->
                try {true, {string:trim(Host), list_to_integer(string:trim(PortStr))}}
                catch _:_ -> false end;
            [Host] ->
                {true, {string:trim(Host), 8080}};
            _ ->
                false
        end
    end, Entries).

%%====================================================================
%% Config helpers (shared with em_filter_server)
%%====================================================================

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

-spec parse_conf(binary()) -> map().
parse_conf(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    {Map, _} = lists:foldl(fun parse_line/2, {#{}, ""}, Lines),
    Map.

parse_line(<<";", _/binary>>, Acc) -> Acc;
parse_line(<<"#", _/binary>>, Acc) -> Acc;
parse_line(<<"[", Rest/binary>>, {Map, _Sec}) ->
    Sec = string:trim(binary_to_list(binary:part(Rest, 0, byte_size(Rest) - 1))),
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
