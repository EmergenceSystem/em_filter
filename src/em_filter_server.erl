%%%-------------------------------------------------------------------
%%% @doc
%%% Generic filter server based on gen_server and Wade HTTP server.
%%% - Starts Wade on a configurable port.
%%% - Exposes a /query endpoint.
%%% - Parses incoming requests (JSON or form-urlencoded).
%%% - Delegates processing to a pluggable handler module.
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-include_lib("wade/include/wade.hrl").

%% API exports
-export([start_link/3, wait_for_lock/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record storing filter info and Wade server PID
-record(filter_state, {
    filter_name :: atom(),
    handler_module :: module(),
    port :: integer(),
    wade_pid :: pid() | undefined
}).

%% ETS table used for synchronization
-define(LOCK_TABLE, 'wade_lock').

%%%-------------------------------------------------------------------
%%% @doc Start the filter server with given name, handler module, and port.
%%%-------------------------------------------------------------------
start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%%-------------------------------------------------------------------
%%% @doc Initialize the filter server: wait for lock, start Wade, register route.
%%%-------------------------------------------------------------------
init({FilterName, HandlerModule, Port}) ->
    wait_for_lock(FilterName),
    process_flag(trap_exit, true),

    case wade:start_link(Port) of
        {ok, WadePid} ->
            io:format("[INIT] Wade started on port ~p~n", [Port]),

            %% Register /query route
            wade:route(post, "/query",
                fun(Req) ->
                    handle_query(Req, HandlerModule)
                end, []),

            persistent_term:put({wade_pid, FilterName}, WadePid),

            io:format("[INIT] Filter server ~p ready~n", [FilterName]),

            {ok, #filter_state{
                filter_name = FilterName,
                handler_module = HandlerModule,
                port = Port,
                wade_pid = WadePid
            }};
        {error, Reason} ->
            io:format("Failed to start Wade: ~p~n", [Reason]),
            {stop, {wade_start_error, Reason}}
    end.

%%%-------------------------------------------------------------------
%%% @doc Handle /query requests, parse body, delegate to handler module.
%%% Supports JSON and form-urlencoded bodies.
%%%-------------------------------------------------------------------
handle_query(Req, HandlerModule) ->
    io:format("=== [HANDLE_QUERY START] ===~n"),
    Body = Req#req.body,
    io:format("[HANDLE_QUERY] Raw Body: ~p~n", [Body]),

    ParsedBody = case Body of
        M when is_map(M) ->
            M;
        L when is_list(L), L =/= [] ->
            case L of
                [{_, _} | _] -> maps:from_list(L);
                _ ->
                    try jsone:decode(list_to_binary(L), [{object_format, map}]) of
                        Map -> Map
                    catch
                        _:_ -> #{}
                    end
            end;
        B when is_binary(B) ->
            try jsone:decode(B, [{object_format, map}]) of
                Map -> Map
            catch
                _:_ -> #{}
            end;
        _ -> #{}
    end,

    io:format("[HANDLE_QUERY] ParsedBody: ~p~n", [ParsedBody]),

    case maps:get(value, ParsedBody, undefined) of
        undefined ->
            RespBody = jsone:encode(#{error => <<"Missing 'value' field">>}),
            {400, RespBody, [{"Content-Type", "application/json"}]};
        _Value ->
            Result = HandlerModule:handle(ParsedBody),
            {200, Result, [{"Content-Type", "application/json"}]}
    end.

%%%-------------------------------------------------------------------
%%% @private Wait until any lock for this filter is released
%%%-------------------------------------------------------------------
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("[LOCK] Waiting for other instance to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.

%%%-------------------------------------------------------------------
%%% gen_server callbacks (trivial)
%%%-------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #filter_state{wade_pid=WadePid}=State) when Pid =:= WadePid ->
    io:format("[INFO] Wade server crashed (~p), stopping filter~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#filter_state.wade_pid of
        undefined -> ok;
        WadePid ->
            catch wade:stop(WadePid),
            persistent_term:erase({wade_pid, State#filter_state.filter_name}),
            ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

