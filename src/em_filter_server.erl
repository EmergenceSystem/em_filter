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

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    filter_name    :: atom(),
    handler_module :: module(),
    conn_pid       :: pid(),
    stream_ref     :: reference()
}).

-define(CONNECT_TIMEOUT, 5000).
-define(UPGRADE_TIMEOUT, 5000).

%%--------------------------------------------------------------------
-spec start_link(atom(), module()) -> {ok, pid()} | {error, term()}.
start_link(FilterName, HandlerModule) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE,
                          {FilterName, HandlerModule}, []).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

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
        _ ->
            ok
    end,
    {noreply, State};

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

terminate(_Reason, #state{conn_pid = Pid}) ->
    gun:close(Pid).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

%% Returns {Host, Port} for em_disco.
%% Priority: env vars > emergence.conf > defaults.
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

%% Reads a single value from emergence.conf.
-spec conf_value(string(), string(), string() | undefined) ->
    string() | undefined.
conf_value(Section, Key, Default) ->
    case read_conf() of
        undefined -> Default;
        Map ->
            Sub = maps:get(Section, Map, #{}),
            maps:get(Key, Sub, Default)
    end.

%% Parses the INI-style emergence.conf file.
-spec read_conf() -> map() | undefined.
read_conf() ->
    Path = conf_path(),
    case Path of
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

%% Minimal INI parser — #{Section => #{Key => Value}}.
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
