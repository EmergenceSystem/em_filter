%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Client for em_disco Connectivity
%%%
%%% `em_filter_server' manages a single persistent WebSocket connection
%%% to an em_disco instance on behalf of one agent.
%%%
%%% === Startup sequence ===
%%%
%%%   1. Open a Gun HTTP connection to the disco address.
%%%   2. Upgrade to WebSocket on /ws.
%%%   3. Send a `register' frame to announce the agent name.
%%%   4. Send an `agent_hello' frame with capabilities (if any).
%%%   5. Initialise the memory backend.
%%%
%%% === Dispatch ===
%%%
%%% Every incoming query frame is dispatched to:
%%%
%%%   HandlerModule:handle(Body :: binary(), Memory :: map()) ->
%%%       {Result :: term(), NewMemory :: map()}
%%%
%%% Memory is always a live map in the gen_server state. The only
%%% difference between `ram' and `ets' backends is persistence across
%%% process restarts — the dispatch path is identical for both.
%%%
%%% === Reconnection ===
%%%
%%% On WS close or connection loss the gen_server stops; the supervisor
%%% restarts it, which reconnects the agent to em_disco.
%%%
%%% === disco address resolution (priority order) ===
%%%
%%%   1. EM_DISCO_HOST / EM_DISCO_PORT environment variables.
%%%   2. [em_disco] section in ~/.config/emergence/emergence.conf.
%%%   3. Default: {"localhost", 8080}.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    agent_name     :: atom(),
    handler_module :: module(),
    conn_pid       :: pid(),
    stream_ref     :: reference(),
    memory         :: map(),              % always a live map
    memory_table   :: atom() | undefined  % undefined when backend is ram
}).

-define(CONNECT_TIMEOUT, 5000).
-define(UPGRADE_TIMEOUT, 5000).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link(atom(), module(), map()) -> {ok, pid()} | {error, term()}.
start_link(AgentName, HandlerModule, Config) ->
    ServerName = list_to_atom(atom_to_list(AgentName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE,
                          {AgentName, HandlerModule, Config}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({AgentName, HandlerModule, Config}) ->
    {Host, Port} = disco_addr(),
    {ok, ConnPid} = gun:open(Host, Port, #{protocols => [http]}),
    case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
        {ok, _} ->
            StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
            receive
                {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
                    register_on_disco(ConnPid, StreamRef, AgentName, Config, Host, Port),
                    {Memory, MemTable} = init_memory(AgentName, Config),
                    {ok, #state{
                        agent_name     = AgentName,
                        handler_module = HandlerModule,
                        conn_pid       = ConnPid,
                        stream_ref     = StreamRef,
                        memory         = Memory,
                        memory_table   = MemTable
                    }};
                {gun_response, ConnPid, _, _, Status, _} ->
                    gun:close(ConnPid),
                    {stop, {ws_rejected, Status}};
                {gun_error, ConnPid, StreamRef, Reason} ->
                    gun:close(ConnPid),
                    {stop, {ws_error, Reason}}
            after ?UPGRADE_TIMEOUT ->
                gun:close(ConnPid),
                {stop, ws_timeout}
            end;
        {error, Reason} ->
            gun:close(ConnPid),
            {stop, {connect_failed, Reason}}
    end.

handle_info({gun_ws, _C, _S, {text, Data}}, State) ->
    case json:decode(Data) of
        #{<<"action">> := <<"query">>, <<"id">> := Id, <<"body">> := Body} ->
            {Result, NewState} = dispatch(Body, State),
            gun:ws_send(State#state.conn_pid, State#state.stream_ref,
                {text, json:encode(#{
                    <<"action">> => <<"result">>,
                    <<"id">>     => Id,
                    <<"data">>   => Result
                })}),
            {noreply, NewState};
        _ ->
            %% Ignore ack frames (registered, agent_registered).
            {noreply, State}
    end;

handle_info({gun_ws, _C, _S, close}, State) ->
    logger:warning("[em_filter] ~s: WS closed, reconnecting...",
                   [State#state.agent_name]),
    {stop, ws_closed, State};

handle_info({gun_down, _C, _P, Reason, _}, State) ->
    logger:warning("[em_filter] ~s: disco unreachable (~p), reconnecting...",
                   [State#state.agent_name, Reason]),
    {stop, {disco_down, Reason}, State};

handle_info(_Info, State)         -> {noreply, State}.
handle_call(_Req, _From, State)   -> {reply, ok, State}.
handle_cast(_Msg, State)          -> {noreply, State}.

terminate(_Reason, #state{conn_pid = Pid, memory_table = Table}) ->
    case Table of
        undefined -> ok;
        T         -> catch ets:delete(T)
    end,
    gun:close(Pid).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal helpers
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Sends `register' then optionally `agent_hello' to em_disco.
%% @end
%%--------------------------------------------------------------------
register_on_disco(ConnPid, StreamRef, AgentName, Config, Host, Port) ->
    gun:ws_send(ConnPid, StreamRef,
        {text, json:encode(#{
            <<"action">> => <<"register">>,
            <<"name">>   => atom_to_binary(AgentName, utf8)
        })}),
    logger:info("[em_filter] ~s registered on disco ~s:~p",
                [AgentName, Host, Port]),
    case maps:get(capabilities, Config, []) of
        [] ->
            ok;
        Caps ->
            gun:ws_send(ConnPid, StreamRef,
                {text, json:encode(#{
                    <<"action">>       => <<"agent_hello">>,
                    <<"capabilities">> => Caps
                })}),
            logger:info("[em_filter] ~s agent_hello caps=~p", [AgentName, Caps])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Dispatches a query to the handler and updates memory.
%%
%% The handler always receives (Body, Memory) and returns
%% {Result, NewMemory}. Memory is updated in the gen_server state
%% and persisted to ETS when the backend is `ets'.
%% @end
%%--------------------------------------------------------------------
-spec dispatch(binary(), #state{}) -> {term(), #state{}}.
dispatch(Body, #state{handler_module = Mod,
                      agent_name     = Name,
                      memory         = Memory,
                      memory_table   = Table} = State) ->
    {Result, NewMemory} = try
        Mod:handle(Body, Memory)
    catch E:R ->
        logger:error("[em_filter] ~s handler error ~p:~p", [Name, E, R]),
        {json:encode(#{<<"error">> => <<"handler_failed">>}), Memory}
    end,
    persist_memory(Table, NewMemory),
    {Result, State#state{memory = NewMemory}}.

%%--------------------------------------------------------------------
%% @private
%% @doc Persists memory to ETS when backend is `ets', no-op otherwise.
%% @end
%%--------------------------------------------------------------------
-spec persist_memory(atom() | undefined, map()) -> ok.
persist_memory(undefined, _Memory) -> ok;
persist_memory(Table, Memory)      -> ets:insert(Table, {memory, Memory}), ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Initialises the memory backend.
%%
%% Returns {InitialMemory, TableName | undefined}.
%%
%% ram (default): starts with #{}, no persistence across restarts.
%% ets:           creates a named ETS table; reloads any previously
%%                stored memory from a prior run in the same session.
%% @end
%%--------------------------------------------------------------------
-spec init_memory(atom(), map()) -> {map(), atom() | undefined}.
init_memory(AgentName, #{memory := ets}) ->
    Table = list_to_atom(atom_to_list(AgentName) ++ "_memory"),
    ets:new(Table, [set, named_table, protected]),
    Memory = case ets:lookup(Table, memory) of
        [{memory, M}] -> M;
        []            -> #{}
    end,
    {Memory, Table};
init_memory(_AgentName, _Config) ->
    {#{}, undefined}.

%%--------------------------------------------------------------------
%% @private
%% @doc Returns {Host, Port} for em_disco.
%% @end
%%--------------------------------------------------------------------
-spec disco_addr() -> {string(), inet:port_number()}.
disco_addr() ->
    Host = case os:getenv("EM_DISCO_HOST") of
        false -> conf_value("em_disco", "host", "localhost");
        H     -> H
    end,
    Port = case os:getenv("EM_DISCO_PORT") of
        false ->
            case conf_value("em_disco", "port", undefined) of
                undefined -> 8080;
                P         -> list_to_integer(P)
            end;
        P -> list_to_integer(P)
    end,
    {Host, Port}.

-spec conf_value(string(), string(), string() | undefined) ->
    string() | undefined.
conf_value(Section, Key, Default) ->
    case read_conf() of
        undefined -> Default;
        Map       -> maps:get(Key, maps:get(Section, Map, #{}), Default)
    end.

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

parse_line(<<"[", Rest/binary>>, {Map, _Sec}) ->
    Sec = string:trim(binary_to_list(binary:part(Rest, 0, byte_size(Rest) - 1))),
    {Map#{Sec => #{}}, Sec};
parse_line(Line, {Map, Sec}) when Sec =/= "" ->
    case binary:split(Line, <<"=">>) of
        [K, V] ->
            Key = string:trim(binary_to_list(K)),
            Val = string:trim(binary_to_list(V)),
            {Map#{Sec => maps:put(Key, Val, maps:get(Sec, Map, #{}))}, Sec};
        _ ->
            {Map, Sec}
    end;
parse_line(_, Acc) -> Acc.
