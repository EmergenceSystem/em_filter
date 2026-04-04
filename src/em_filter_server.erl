%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Client for em_disco Connectivity
%%%
%%% Manages a single persistent WebSocket connection to ONE em_disco
%%% node. em_filter_sup starts one server per configured disco node.
%%%
%%% === Connection lifecycle ===
%%%
%%% 1. `init/1' sends `self() ! connect' and returns immediately.
%%% 2. `handle_info(connect, ...)' opens a Gun connection, upgrades to
%%%    WebSocket and completes the 2-step handshake.
%%% 3. On connection loss, a reconnect is scheduled after
%%%    `reconnect_interval_ms' milliseconds (application env).
%%%
%%% The server process never stops due to transient network failures —
%%% reconnection is handled internally. ETS memory (if configured)
%%% survives reconnects because it is owned by the server process.
%%%
%%% === Authentication ===
%%%
%%% em_disco requires a JWT passed as `?token=<jwt>' in the WebSocket
%%% upgrade URL. The token is read from (in order of priority):
%%%   1. `jwt_token' key in the agent Config map
%%%   2. `jwt_token' application env in the `em_filter' application
%%%
%%% If no token is configured the upgrade will be rejected with 401;
%%% the server logs a warning and schedules a reconnect.
%%%
%%% === Transport ===
%%%
%%% tcp — plain WebSocket  (ws://)
%%% tls — TLS  WebSocket  (wss://)
%%%
%%% TLS uses verify_peer with the system CA store. SNI is set to the
%%% target host so wildcard certificates are validated correctly.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-export([start_link/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    agent_name      :: atom(),
    handler_module  :: module(),
    config          :: map(),
    host            :: string(),
    port            :: inet:port_number(),
    transport       :: tcp | tls,
    conn_pid        :: pid() | undefined,
    stream_ref      :: reference() | undefined,
    memory          :: map(),
    memory_table    :: atom() | undefined,
    reconnect_timer :: reference() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts a server linked to one specific disco node.
%%
%% Index controls the registered process name:
%%   1       → `<agent>_server'
%%   2, 3, … → `<agent>_server_<N>'
%%
%% This ensures `whereis(my_agent_server)' works for the common
%% single-node case while still supporting multi-node setups.
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), module(), map(),
                 {string(), inet:port_number(), tcp | tls},
                 pos_integer()) ->
    {ok, pid()} | {error, term()}.
start_link(AgentName, HandlerModule, Config, {Host, Port, Transport}, Index) ->
    ServerName = server_name(AgentName, Index),
    gen_server:start_link({local, ServerName}, ?MODULE,
                          {AgentName, HandlerModule, Config,
                           Host, Port, Transport}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Initialises the server state and schedules the first connection attempt.
%%
%% Memory is loaded from ETS if `memory => ets' is configured, otherwise
%% starts as an empty map. The actual WebSocket connection is deferred to
%% the first `handle_info(connect, ...)' call.
%% @end
%%--------------------------------------------------------------------
-spec init({atom(), module(), map(), string(), inet:port_number(), tcp | tls}) ->
    {ok, #state{}}.
init({AgentName, HandlerModule, Config, Host, Port, Transport}) ->
    {Memory, MemTable} = init_memory(AgentName, Config),
    self() ! connect,
    {ok, #state{
        agent_name      = AgentName,
        handler_module  = HandlerModule,
        config          = Config,
        host            = Host,
        port            = Port,
        transport       = Transport,
        conn_pid        = undefined,
        stream_ref      = undefined,
        memory          = Memory,
        memory_table    = MemTable,
        reconnect_timer = undefined
    }}.

%%--------------------------------------------------------------------
%% @doc Handles incoming WebSocket frames from em_disco.
%%
%% Only `query' frames are processed — registration ack frames
%% (registered, agent_registered) are silently ignored.
%% @end
%%--------------------------------------------------------------------
handle_info({gun_ws, _C, _S, {text, Data}}, State) ->
    case json:decode(Data) of
        #{<<"action">> := <<"query">>, <<"id">> := Id, <<"body">> := Body} ->
            logger:notice("[em_filter] query: ~ts", [Body]),
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

%%--------------------------------------------------------------------
%% @doc Attempts to open a Gun connection and upgrade to WebSocket.
%%
%% On any failure (connect error, upgrade timeout, 401, etc.) the
%% server schedules another `connect' message after
%% `reconnect_interval_ms' milliseconds.
%% @end
%%--------------------------------------------------------------------
handle_info(connect, #state{conn_pid = P} = State) when P =/= undefined ->
    %% Already connected — stale connect message, ignore.
    {noreply, State};

handle_info(connect, #state{host       = Host,
                             port       = Port,
                             transport  = Transport,
                             agent_name = Name,
                             config     = Config} = State) ->
    GunOpts = gun_opts(Transport, Host),
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, connect_timeout()) of
                {ok, _} ->
                    Token     = resolve_token(Config),
                    Path      = ws_path(Token),
                    StreamRef = gun:ws_upgrade(ConnPid, Path),
                    receive
                        {gun_upgrade, ConnPid, StreamRef,
                         [<<"websocket">>], _} ->
                            register_on_disco(ConnPid, StreamRef,
                                              Name, Config),
                            logger:notice("[em_filter] agent connected: ~ts @ ~s:~p",
                                [Name, Host, Port]),
                            {noreply, State#state{
                                conn_pid        = ConnPid,
                                stream_ref      = StreamRef,
                                reconnect_timer = undefined
                            }};
                        {gun_response, ConnPid, _, _, 401, _} ->
                            gun:close(ConnPid),
                            logger:warning("WS auth rejected (401)",
                                #{agent => Name, host => Host, port => Port}),
                            Ref = schedule_reconnect(),
                            {noreply, State#state{
                                conn_pid        = undefined,
                                reconnect_timer = Ref
                            }};
                        {gun_response, ConnPid, _, _, Status, _} ->
                            gun:close(ConnPid),
                            logger:warning("WS upgrade rejected",
                                #{agent => Name, status => Status}),
                            Ref = schedule_reconnect(),
                            {noreply, State#state{
                                conn_pid        = undefined,
                                reconnect_timer = Ref
                            }};
                        {gun_error, ConnPid, StreamRef, Reason} ->
                            gun:close(ConnPid),
                            logger:warning("WS upgrade error",
                                #{agent => Name, reason => Reason}),
                            Ref = schedule_reconnect(),
                            {noreply, State#state{
                                conn_pid        = undefined,
                                reconnect_timer = Ref
                            }}
                    after upgrade_timeout() ->
                        gun:close(ConnPid),
                        logger:warning("WS upgrade timeout",
                            #{agent => Name, host => Host, port => Port}),
                        Ref = schedule_reconnect(),
                        {noreply, State#state{
                            conn_pid        = undefined,
                            reconnect_timer = Ref
                        }}
                    end;
                {error, Reason} ->
                    gun:close(ConnPid),
                    logger:warning("Connect failed",
                        #{agent => Name, host => Host,
                          port => Port, reason => Reason}),
                    Ref = schedule_reconnect(),
                    {noreply, State#state{
                        conn_pid        = undefined,
                        reconnect_timer = Ref
                    }}
            end;
        {error, Reason} ->
            logger:warning("gun:open failed",
                #{agent => Name, host => Host, port => Port, reason => Reason}),
            Ref = schedule_reconnect(),
            {noreply, State#state{reconnect_timer = Ref}}
    end;

handle_info({gun_ws, C, _S, close}, #state{conn_pid = C} = State) ->
    logger:warning("WS closed, scheduling reconnect",
                   #{agent => State#state.agent_name}),
    safe_close(C),
    Ref = schedule_reconnect(),
    {noreply, State#state{conn_pid        = undefined,
                          stream_ref      = undefined,
                          reconnect_timer = Ref}};
handle_info({gun_ws, _C, _S, close}, State) ->
    %% Stale close from a previous connection, ignore.
    {noreply, State};

handle_info({gun_down, C, _P, Reason, _}, #state{conn_pid = C} = State) ->
    logger:warning("Disco unreachable, scheduling reconnect",
                   #{agent => State#state.agent_name, reason => Reason}),
    safe_close(C),
    Ref = schedule_reconnect(),
    {noreply, State#state{conn_pid        = undefined,
                          stream_ref      = undefined,
                          reconnect_timer = Ref}};
handle_info({gun_down, _C, _P, _Reason, _}, State) ->
    %% Stale gun_down from a previous connection, ignore.
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc No synchronous calls — returns `ok' for any request.
%% @end
%%--------------------------------------------------------------------
-spec handle_call(term(), {pid(), term()}, #state{}) -> {reply, ok, #state{}}.
handle_call(_Req, _From, State) -> {reply, ok, State}.

%%--------------------------------------------------------------------
%% @doc No asynchronous casts handled.
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State)        -> {noreply, State}.

%%--------------------------------------------------------------------
%% @doc Cancels the reconnect timer, closes the Gun connection, and
%% deletes the ETS memory table if one was created.
%% @end
%%--------------------------------------------------------------------
-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{conn_pid        = ConnPid,
                           memory_table   = Table,
                           reconnect_timer = Timer}) ->
    case Timer of
        undefined -> ok;
        R         -> erlang:cancel_timer(R)
    end,
    safe_close(ConnPid),
    case Table of
        undefined -> ok;
        T         -> catch ets:delete(T)
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal helpers
%%====================================================================

%% @private
-spec server_name(atom(), pos_integer()) -> atom().
server_name(AgentName, 1) ->
    list_to_atom(atom_to_list(AgentName) ++ "_server");
server_name(AgentName, N) ->
    list_to_atom(atom_to_list(AgentName) ++ "_server_" ++ integer_to_list(N)).

%%--------------------------------------------------------------------
%% @private
%% @doc Builds Gun transport options.
%%
%% tcp — plain connection.
%% tls — TLS with system CA store. SNI set to Host so wildcard
%%       certificates are validated correctly.
%% @end
%%--------------------------------------------------------------------
-spec gun_opts(tcp | tls, string()) -> map().
gun_opts(tls, Host) ->
    Sni = case is_binary(Host) of
        true  -> binary_to_list(Host);
        false -> Host
    end,
    #{protocols => [http],
      transport => tls,
      tls_opts  => [{verify, verify_peer},
                    {cacerts, public_key:cacerts_get()},
                    {server_name_indication, Sni},
                    {customize_hostname_check,
                     [{match_fun,
                       public_key:pkix_verify_hostname_match_fun(https)}]}]};
gun_opts(tcp, _Host) ->
    #{protocols => [http]}.

%%--------------------------------------------------------------------
%% @private
%% @doc Sends the 2-step registration handshake to em_disco.
%%
%% Both frames are always sent:
%%   1. `register'    — announces the agent name.
%%   2. `agent_hello' — announces capabilities (may be empty list).
%%
%% Without `agent_hello', em_disco does not insert the agent into
%% its registry and the agent will not receive any queries.
%% @end
%%--------------------------------------------------------------------
-spec register_on_disco(pid(), reference(), atom(), map()) -> ok.
register_on_disco(ConnPid, StreamRef, AgentName, Config) ->
    gun:ws_send(ConnPid, StreamRef,
        {text, json:encode(#{
            <<"action">> => <<"register">>,
            <<"name">>   => atom_to_binary(AgentName, utf8)
        })}),
    Caps = maps:get(capabilities, Config, []),
    gun:ws_send(ConnPid, StreamRef,
        {text, json:encode(#{
            <<"action">>       => <<"agent_hello">>,
            <<"capabilities">> => Caps
        })}).

%% @private
-spec dispatch(binary(), #state{}) -> {term(), #state{}}.
dispatch(Body, #state{handler_module = Mod,
                      agent_name     = Name,
                      memory         = Memory,
                      memory_table   = Table} = State) ->
    {Result, NewMemory} = try
        Mod:handle(Body, Memory)
    catch E:R ->
        logger:error("Handler error",
                     #{agent => Name, class => E, reason => R}),
        {json:encode(#{<<"error">> => <<"handler_failed">>}), Memory}
    end,
    persist_memory(Table, NewMemory),
    {Result, State#state{memory = NewMemory}}.

%% @private
-spec persist_memory(atom() | undefined, map()) -> ok.
persist_memory(undefined, _Memory) -> ok;
persist_memory(Table, Memory)      ->
    ets:insert(Table, {memory, Memory}), ok.

%% @private
-spec init_memory(atom(), map()) -> {map(), atom() | undefined}.
init_memory(AgentName, #{memory := ets}) ->
    Table  = list_to_atom(atom_to_list(AgentName) ++ "_memory"),
    ets:new(Table, [set, named_table, protected]),
    Memory = case ets:lookup(Table, memory) of
        [{memory, M}] -> M;
        []            -> #{}
    end,
    {Memory, Table};
init_memory(_AgentName, _Config) ->
    {#{}, undefined}.

%% @private
-spec resolve_token(map()) -> binary() | undefined.
resolve_token(Config) ->
    case maps:get(jwt_token, Config, undefined) of
        undefined ->
            application:get_env(em_filter, jwt_token, undefined);
        T -> T
    end.

%% @private
-spec ws_path(binary() | undefined) -> string().
ws_path(undefined)                   -> "/ws";
ws_path(Token) when is_binary(Token) ->
    binary_to_list(<<"/ws?token=", Token/binary>>).

%% @private
-spec schedule_reconnect() -> reference().
schedule_reconnect() ->
    erlang:send_after(reconnect_delay(), self(), connect).

%% @private
-spec safe_close(pid() | undefined) -> ok.
safe_close(undefined) -> ok;
safe_close(Pid)       -> gun:close(Pid), ok.

%% @private
-spec connect_timeout() -> pos_integer().
connect_timeout() ->
    application:get_env(em_filter, connect_timeout_ms, 5000).

%% @private
-spec upgrade_timeout() -> pos_integer().
upgrade_timeout() ->
    application:get_env(em_filter, upgrade_timeout_ms, 5000).

%% @private
-spec reconnect_delay() -> pos_integer().
reconnect_delay() ->
    application:get_env(em_filter, reconnect_interval_ms, 5000).
