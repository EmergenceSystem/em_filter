%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Client for em_disco Connectivity
%%%
%%% `em_filter_server' is a `gen_server' that manages a single
%%% persistent WebSocket connection to an `em_disco' discovery
%%% service instance.
%%%
%%% On startup it:
%%% <ol>
%%%   <li>Opens a Gun HTTP connection to the configured disco address.</li>
%%%   <li>Upgrades the connection to WebSocket on the `/ws' path.</li>
%%%   <li>Sends a `register' frame so that `em_disco' can route
%%%       incoming queries to this filter.</li>
%%%   <li>(Agents only) Sends an `agent_hello' frame with capabilities
%%%       so that `em_disco' can register the node in its agent
%%%       registry.</li>
%%% </ol>
%%%
%%% When a query frame arrives the server invokes the handler module:
%%% <ul>
%%%   <li>Plain filters — `HandlerModule:handle/1'  (Body)</li>
%%%   <li>Agents with memory — `HandlerModule:handle/2'  (Body, Memory)
%%%       which must return `{Result, NewMemory}'.</li>
%%% </ul>
%%%
%%% Connection failures and remote closes are handled by stopping
%%% the gen_server with a descriptive reason; the supervisor
%%% (`em_filter_sup') will restart it, effectively re-connecting.
%%%
%%% === Configuration ===
%%%
%%% The disco address is read from `~/.config/emergence/emergence.conf'
%%% (or `%APPDATA%\emergence\emergence.conf' on Windows) under the
%%% `[em_disco]' section, or from the `EM_DISCO_HOST' / `EM_DISCO_PORT'
%%% environment variables.
%%%
%%% Defaults to `{"localhost", 8080}' when the config is absent.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-export([start_link/2, start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    filter_name    :: atom(),
    handler_module :: module(),
    conn_pid       :: pid(),
    stream_ref     :: reference(),
    %% Agent-only fields — both undefined when started via start_link/2.
    memory         :: map() | undefined,
    memory_table   :: atom() | undefined
}).

-define(CONNECT_TIMEOUT, 5000).
-define(UPGRADE_TIMEOUT, 5000).

%%====================================================================
%% Public API
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts a plain filter server (unchanged from 1.0.0).
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), module()) -> {ok, pid()} | {error, term()}.
start_link(FilterName, HandlerModule) ->
    start_link(FilterName, HandlerModule, #{}).

%%--------------------------------------------------------------------
%% @doc Starts an agent server with an optional config map.
%%
%% When `Config' is `#{}' the behaviour is identical to
%% `start_link/2' — no `agent_hello' is sent and no memory is
%% initialised.
%%
%% Recognised config keys:
%% <ul>
%%   <li>`capabilities' — `[binary()]' — sent as `agent_hello' after
%%       registration.  Defaults to `[]' (no hello sent).</li>
%%   <li>`memory' — `none | ets' — memory backend.  Defaults to
%%       `none'.</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), module(), map()) -> {ok, pid()} | {error, term()}.
start_link(FilterName, HandlerModule, Config) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE,
                          {FilterName, HandlerModule, Config}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({FilterName, HandlerModule, Config}) ->
    {Host, Port} = disco_addr(),
    {ok, ConnPid} = gun:open(Host, Port, #{protocols => [http]}),
    case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
        {ok, _} ->
            StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
            receive
                {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
                    %% ── Step 1: register (identical for filters and agents) ──
                    Payload = json:encode(#{
                        <<"action">> => <<"register">>,
                        <<"name">>   => atom_to_binary(FilterName, utf8)
                    }),
                    gun:ws_send(ConnPid, StreamRef, {text, Payload}),
                    logger:info("[em_filter] ~s registered on disco ~s:~p",
                                [FilterName, Host, Port]),

                    %% ── Step 2: agent_hello (agents only) ────────────────────
                    %%
                    %% Only sent when the config map provides at least one
                    %% capability.  Plain filters started via start_link/2
                    %% receive an empty config and never reach this branch.
                    Caps = maps:get(capabilities, Config, []),
                    case Caps of
                        [] ->
                            ok;
                        _ ->
                            Hello = json:encode(#{
                                <<"action">>       => <<"agent_hello">>,
                                <<"capabilities">> => Caps
                            }),
                            gun:ws_send(ConnPid, StreamRef, {text, Hello}),
                            logger:info("[em_filter] ~s sent agent_hello caps=~p",
                                        [FilterName, Caps])
                    end,

                    %% ── Step 3: initialise memory backend (agents only) ───────
                    {Memory, MemTable} = init_memory(FilterName, Config),

                    {ok, #state{
                        filter_name    = FilterName,
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

%%--------------------------------------------------------------------
%% @doc Handles incoming WebSocket frames from em_disco.
%%
%% `query' frames are dispatched to the handler module:
%% <ul>
%%   <li>If memory is disabled (`memory = undefined'), calls
%%       `HandlerModule:handle/1' — identical to 1.0.0 behaviour.</li>
%%   <li>If memory is enabled, calls `HandlerModule:handle/2' which
%%       must return `{Result, NewMemory}'.  The updated memory is
%%       stored back in the ETS table for the next query.</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
handle_info({gun_ws, _C, _S, {text, Data}}, State) ->
    case json:decode(Data) of
        #{<<"action">> := <<"query">>,
          <<"id">>     := Id,
          <<"body">>   := Body} ->
            {Result, NewState} = dispatch(Body, State),
            gun:ws_send(State#state.conn_pid, State#state.stream_ref,
                {text, json:encode(#{
                    <<"action">> => <<"result">>,
                    <<"id">>     => Id,
                    <<"data">>   => Result
                })}),
            {noreply, NewState};
        _ ->
            {noreply, State}
    end;

handle_info({gun_ws, _C, _S, close}, State) ->
    logger:warning("[em_filter] ~s: WS closed, reconnecting...",
                   [State#state.filter_name]),
    {stop, ws_closed, State};

handle_info({gun_down, _C, _P, Reason, _}, State) ->
    logger:warning("[em_filter] ~s: disco unreachable (~p), reconnecting...",
                   [State#state.filter_name, Reason]),
    {stop, {disco_down, Reason}, State};

handle_info(_Info, State) -> {noreply, State}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State)        -> {noreply, State}.

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
%% @doc Calls the handler module and updates memory if applicable.
%%
%% Plain filter path (memory = undefined):
%%   Calls handle/1 — identical to 1.0.0.
%%
%% Agent path (memory is a map):
%%   Calls handle/2 with the current memory map.
%%   Expects {Result, NewMemory} in return.
%%   Persists NewMemory to ETS for the next query.
%% @end
%%--------------------------------------------------------------------
-spec dispatch(binary(), #state{}) -> {term(), #state{}}.
dispatch(Body, #state{memory = undefined} = State) ->
    Result = try
        (State#state.handler_module):handle(Body)
    catch E:R ->
        logger:error("[em_filter] ~s handler error ~p:~p",
                     [State#state.filter_name, E, R]),
        json:encode(#{<<"error">> => <<"handler_failed">>})
    end,
    {Result, State};
dispatch(Body, #state{memory = Memory, memory_table = Table,
                      filter_name = Name} = State) ->
    {Result, NewMemory} = try
        (State#state.handler_module):handle(Body, Memory)
    catch E:R ->
        logger:error("[em_filter] ~s agent handler error ~p:~p", [Name, E, R]),
        {json:encode(#{<<"error">> => <<"handler_failed">>}), Memory}
    end,
    %% Persist updated memory to ETS so it survives across queries.
    ets:insert(Table, {memory, NewMemory}),
    {Result, State#state{memory = NewMemory}}.

%%--------------------------------------------------------------------
%% @private
%% @doc Initialises the memory backend described in Config.
%%
%% Returns `{Memory, TableName | undefined}'.
%%
%% `none' (default) — no memory, returns `{undefined, undefined}'.
%% `ets'            — creates a private ETS table named after the
%%                    agent and returns the initial empty map.
%% @end
%%--------------------------------------------------------------------
-spec init_memory(atom(), map()) -> {map() | undefined, atom() | undefined}.
init_memory(_FilterName, #{memory := none}) ->
    {undefined, undefined};
init_memory(FilterName, #{memory := ets}) ->
    TableName = list_to_atom(atom_to_list(FilterName) ++ "_memory"),
    ets:new(TableName, [set, named_table, protected]),
    InitialMemory = case ets:lookup(TableName, memory) of
        [{memory, M}] -> M;
        []            -> #{}
    end,
    {InitialMemory, TableName};
init_memory(_FilterName, _Config) ->
    %% No memory key in config — plain filter behaviour.
    {undefined, undefined}.

%%--------------------------------------------------------------------
%% @private
%% @doc Returns {Host, Port} for em_disco.
%%      Priority: env vars > emergence.conf > defaults.
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
        Map ->
            Sub = maps:get(Section, Map, #{}),
            maps:get(Key, Sub, Default)
    end.

-spec read_conf() -> map() | undefined.
read_conf() ->
    case conf_path() of
        undefined -> undefined;
        P ->
            case file:read_file(P) of
                {ok, Bin} -> parse_conf(Bin);
                _         -> undefined
            end
    end.

-spec conf_path() -> string() | undefined.
conf_path() ->
    case os:getenv("HOME") of
        false ->
            case os:getenv("APPDATA") of
                false   -> undefined;
                AppData -> filename:join([AppData, "emergence", "emergence.conf"])
            end;
        Home ->
            case os:type() of
                {unix,  _} ->
                    filename:join([Home, ".config", "emergence", "emergence.conf"]);
                {win32, _} ->
                    filename:join([Home, "AppData", "Roaming", "emergence", "emergence.conf"])
            end
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
            Sub = maps:get(Sec, Map, #{}),
            {Map#{Sec => Sub#{Key => Val}}, Sec};
        _ ->
            {Map, Sec}
    end;
parse_line(_, Acc) -> Acc.
