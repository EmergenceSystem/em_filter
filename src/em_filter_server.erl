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
%%% </ol>
%%%
%%% When a query frame arrives the server invokes
%%% `HandlerModule:handle/1' and sends the result back to disco
%%% as a `result' frame.
%%%
%%% Connection failures and remote closes are handled by stopping
%%% the gen_server with a descriptive reason; the supervisor
%%% (`em_filter_sup') will restart it, effectively re-connecting.
%%%
%%% === Configuration ===
%%%
%%% The disco address is read from `embryo:read_emergence_conf/0'
%%% under the `"em_disco"' key:
%%%
%%% ```
%%% {
%%%   "em_disco": {
%%%     "host": "my-disco-host",
%%%     "port": 8080
%%%   }
%%% }
%%% '''
%%%
%%% Defaults to `{"localhost", 8080}' when the config is absent.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Per-connection state.
-record(state, {
    filter_name    :: atom(),     %% Registered name of this filter instance.
    handler_module :: module(),   %% Module whose handle/1 processes queries.
    conn_pid       :: pid(),      %% Gun connection process.
    stream_ref     :: reference() %% Gun WebSocket stream reference.
}).

%% Timeout waiting for the Gun connection to reach the `up' state.
-define(CONNECT_TIMEOUT, 5000).
%% Timeout waiting for the WebSocket upgrade handshake to complete.
-define(UPGRADE_TIMEOUT, 5000).

%%--------------------------------------------------------------------
%% @doc Starts the gen_server and links it to the calling process.
%%
%% The process is registered locally under the name
%% `<FilterName>_server'.
%%
%% @param FilterName    Atom identifying this filter; used as the
%%                      registration key in `em_disco'.
%% @param HandlerModule Module exporting `handle/1'.
%% @return `{ok, Pid}' on success, `{error, Reason}' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec start_link(atom(), module()) -> {ok, pid()} | {error, term()}.
start_link(FilterName, HandlerModule) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE,
                          {FilterName, HandlerModule}, []).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

%% @private
init({FilterName, HandlerModule}) ->
    {Host, Port} = disco_addr(),
    {ok, ConnPid} = gun:open(Host, Port, #{protocols => [http]}),
    case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
        {ok, _} ->
            StreamRef = gun:ws_upgrade(ConnPid, "/ws"),
            receive
                {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} ->
                    Payload = json:encode(#{
                        <<"action">> => <<"register">>,
                        <<"name">>   => atom_to_binary(FilterName, utf8)
                    }),
                    gun:ws_send(ConnPid, StreamRef, {text, Payload}),
                    logger:info("[em_filter] ~s registered on disco ~s:~p",
                                [FilterName, Host, Port]),
                    {ok, #state{filter_name    = FilterName,
                                handler_module = HandlerModule,
                                conn_pid       = ConnPid,
                                stream_ref     = StreamRef}};
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
%% @private
%% @doc Dispatches incoming WebSocket frames from `em_disco'.
%%
%% Handles two frame types:
%% <ul>
%%%   <li>A `query' action frame — invokes `HandlerModule:handle/1'
%%%       with the query body and sends the result back as a `result'
%%%       frame. Handler crashes are caught, logged, and reported
%%%       to disco as an error payload.</li>
%%%   <li>A `close' frame — stops the server so the supervisor
%%%       can restart and re-connect.</li>
%%% </ul>
%%% Acknowledgement frames (e.g. `registered') and any other frames
%%% are silently ignored.
%% @end
%%--------------------------------------------------------------------
handle_info({gun_ws, _C, _S, {text, Data}}, State) ->
    case json:decode(Data) of
        #{<<"action">> := <<"query">>,
          <<"id">>     := Id,
          <<"body">>   := Body} ->
            Result = try
                (State#state.handler_module):handle(Body)
            catch E:R ->
                logger:error("[em_filter] ~s handler error ~p:~p",
                             [State#state.filter_name, E, R]),
                json:encode(#{<<"error">> => <<"handler_failed">>})
            end,
            gun:ws_send(State#state.conn_pid, State#state.stream_ref,
                {text, json:encode(#{
                    <<"action">> => <<"result">>,
                    <<"id">>     => Id,
                    <<"data">>   => Result
                })});
        %% Acknowledgement frames from disco (e.g. registered) — ignore.
        _ ->
            ok
    end,
    {noreply, State};

%% @private
%% disco closed the WebSocket — stop so the supervisor re-connects.
handle_info({gun_ws, _C, _S, close}, State) ->
    logger:warning("[em_filter] ~s: WS closed, reconnecting...",
                   [State#state.filter_name]),
    {stop, ws_closed, State};

%% @private
%% Network-level failure — stop so the supervisor re-connects.
handle_info({gun_down, _C, _P, Reason, _}, State) ->
    logger:warning("[em_filter] ~s: disco unreachable (~p), reconnecting...",
                   [State#state.filter_name, Reason]),
    {stop, {disco_down, Reason}, State};

handle_info(_Info, State) -> {noreply, State}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State)        -> {noreply, State}.

%% @private
%% Closes the Gun connection gracefully on shutdown.
terminate(_Reason, #state{conn_pid = Pid}) ->
    gun:close(Pid).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

%% Returns the {Host, Port} of the em_disco instance to connect to.
%% Falls back to {"localhost", 8080} when no configuration is found.
-spec disco_addr() -> {string(), inet:port_number()}.
disco_addr() ->
    case embryo:read_emergence_conf() of
        undefined -> {"localhost", 8080};
        Map ->
            Sub  = maps:get("em_disco", Map, #{}),
            Host = maps:get("host", Sub, "localhost"),
            Port = maps:get("port", Sub, 8080),
            {Host, Port}
    end.
