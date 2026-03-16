%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket Client for em_disco Connectivity
%%%
%%% `em_filter_server' manages a single persistent WebSocket connection
%%% to ONE em_disco node on behalf of one agent.
%%%
%%% em_filter_sup starts one em_filter_server per configured disco node,
%%% so an agent with N nodes in its config runs N parallel workers —
%%% each receiving queries from its disco and replying independently.
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
%%% === Reconnection ===
%%%
%%% On WS close or connection loss the gen_server stops; the supervisor
%%% restarts it, which reconnects the agent to em_disco.
%%%
%%% === Disco address resolution (priority order) ===
%%%
%%%   1. {Host, Port} passed explicitly by em_filter_sup.
%%%   2. EM_DISCO_HOST / EM_DISCO_PORT environment variables
%%%      (used only when sup passes no explicit address).
%%%   3. [em_disco] nodes list in emergence.conf.
%%%   4. Default: {"localhost", 8080}.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-export([start_link/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    agent_name     :: atom(),
    handler_module :: module(),
    conn_pid       :: pid(),
    stream_ref     :: reference(),
    memory         :: map(),
    memory_table   :: atom() | undefined
}).

-define(CONNECT_TIMEOUT, 5000).
-define(UPGRADE_TIMEOUT, 5000).

%%====================================================================
%% Public API
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts a server linked to one specific disco node.
%%
%% ServerName is derived from AgentName + node index so multiple
%% workers for the same agent have distinct registered names.
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), module(), map(), {string(), inet:port_number()}) ->
    {ok, pid()} | {error, term()}.
start_link(AgentName, HandlerModule, Config, {Host, Port}) ->
    %% Encode host into the server name so each disco node gets its
    %% own registered process — avoids name clashes when an agent
    %% connects to multiple disco nodes.
    SafeHost  = re:replace(Host, "[^a-zA-Z0-9]", "_", [global, {return, list}]),
    ServerName = list_to_atom(atom_to_list(AgentName) ++ "_" ++ SafeHost
                              ++ "_" ++ integer_to_list(Port)),
    gen_server:start_link({local, ServerName}, ?MODULE,
                          {AgentName, HandlerModule, Config, Host, Port}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({AgentName, HandlerModule, Config, Host, Port}) ->
    {ok, ConnPid} = gun:open(Host, Port, #{protocols => [http]}),
    case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
        {ok, _} ->
            StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
            receive
                {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
                    register_on_disco(ConnPid, StreamRef, AgentName, Config,
                                      Host, Port),
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

handle_info(_Info, State)       -> {noreply, State}.
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

register_on_disco(ConnPid, StreamRef, AgentName, Config, Host, Port) ->
    gun:ws_send(ConnPid, StreamRef,
        {text, json:encode(#{
            <<"action">> => <<"register">>,
            <<"name">>   => atom_to_binary(AgentName, utf8)
        })}),
    logger:info("[em_filter] ~s registered on disco ~s:~p",
                [AgentName, Host, Port]),
    case maps:get(capabilities, Config, []) of
        [] -> ok;
        Caps ->
            gun:ws_send(ConnPid, StreamRef,
                {text, json:encode(#{
                    <<"action">>       => <<"agent_hello">>,
                    <<"capabilities">> => Caps
                })}),
            logger:info("[em_filter] ~s agent_hello caps=~p", [AgentName, Caps])
    end.

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

-spec persist_memory(atom() | undefined, map()) -> ok.
persist_memory(undefined, _Memory) -> ok;
persist_memory(Table, Memory)      -> ets:insert(Table, {memory, Memory}), ok.

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
