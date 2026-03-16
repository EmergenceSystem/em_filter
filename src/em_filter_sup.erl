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
%%% === Node format in emergence.conf ===
%%%
%%%   nodes = localhost:8080, em_disco.roques.me
%%%
%%% Port resolution rules (applied when no port is given):
%%%   localhost / 127.0.0.1  → 8080, plain TCP
%%%   any other host         → 443,  TLS
%%%
%%% Explicit port always wins:
%%%   localhost:9000         → 9000, plain TCP
%%%   example.com:8080       → 8080, plain TCP (non-standard, no TLS)
%%%   example.com:443        → 443,  TLS
%%%
%%% TLS is used when port = 443 OR host is not localhost/127.0.0.1
%%% and no explicit port was given.
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
%% @param HandlerModule Module exporting handle/2.
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
                case process_info(P, registered_name) of
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
%% @doc Returns the list of disco nodes as {Host, Port, Transport}.
%%
%% Priority order:
%%   1. EM_DISCO_HOST / EM_DISCO_PORT env vars (legacy, single node)
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
            [{" localhost", P, port_transport("localhost", P)}];
        {Host, Port} ->
            P = list_to_integer(Port),
            [{Host, P, port_transport(Host, P)}]
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Parses the nodes key from [em_disco] in emergence.conf.
%%
%% Accepts entries in any of these forms:
%%   localhost              → {"localhost", 8080, tcp}
%%   localhost:8080         → {"localhost", 8080, tcp}
%%   localhost:9000         → {"localhost", 9000, tcp}
%%   em_disco.roques.me     → {"em_disco.roques.me", 443, tls}
%%   em_disco.roques.me:443 → {"em_disco.roques.me", 443, tls}
%%   em_disco.roques.me:8080→ {"em_disco.roques.me", 8080, tcp}
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
                    %% Legacy host + port keys.
                    Host = maps:get("host", Section, "localhost"),
                    Port = list_to_integer(
                               maps:get("port", Section, "8080")),
                    [{Host, Port, port_transport(Host, Port)}];
                NodesStr ->
                    parse_nodes(NodesStr)
            end
    end.

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

%%--------------------------------------------------------------------
%% @private
%% @doc Returns {DefaultPort, Transport} when no port was specified.
%%
%% localhost / 127.0.0.1 → {8080, tcp}
%% any other host        → {443,  tls}
%% @end
%%--------------------------------------------------------------------
-spec default_port_transport(string(), undefined) ->
    {inet:port_number(), tcp | tls}.
default_port_transport("localhost",  _) -> {8080, tcp};
default_port_transport("127.0.0.1", _) -> {8080, tcp};
default_port_transport(_Host,       _) -> {443,  tls}.

%%--------------------------------------------------------------------
%% @private
%% @doc Returns the transport for an explicit {Host, Port} pair.
%%
%% Port 443  → tls  (standard HTTPS/WSS)
%% Port 80   → tcp  (standard HTTP/WS)
%% localhost → tcp  (always plain, regardless of port)
%% other     → tcp  (non-standard explicit port, assume plain)
%% @end
%%--------------------------------------------------------------------
-spec port_transport(string(), inet:port_number()) -> tcp | tls.
port_transport("localhost",  _)   -> tcp;
port_transport("127.0.0.1", _)   -> tcp;
port_transport(_Host,       443)  -> tls;
port_transport(_Host,       _)    -> tcp.

%%====================================================================
%% Config helpers
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
    %% string:trim handles both ] and \r for Windows line endings.
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
