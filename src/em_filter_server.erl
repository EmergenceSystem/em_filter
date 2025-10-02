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
    BodyRaw = Req#req.body,
    io:format("[HANDLE_QUERY] Raw Body: ~p (type: ~p)~n", [BodyRaw, type_of(BodyRaw)]),

    %% Parse body into a map
    ParsedBody = parse_body(BodyRaw),
    io:format("[HANDLE_QUERY] ParsedBody: ~p~n", [ParsedBody]),

    %% Extract the query value
    QueryValue = case ParsedBody of
        Map when is_map(Map) ->
            case maps:get(value, Map, undefined) of
                undefined -> maps:get(query, Map, <<>>);
                V -> V
            end;
        _ -> <<>>
    end,

    io:format("[HANDLE_QUERY] Final QueryValue: ~p~n", [QueryValue]),

    %% Check if query is empty
    case QueryValue of
        <<>> ->
            RespBody = jsone:encode(#{<<"error">> => <<"Missing or empty 'value' field">>}),
            {400, RespBody, [{"Content-Type", "application/json"}]};
        _ ->
            try
                Result = HandlerModule:handle(QueryValue),
                {200, Result, [{"Content-Type", "application/json"}]}
            catch
                Error:Reason ->
                    io:format("[HANDLE_QUERY ERROR] ~p:~p~n", [Error, Reason]),
                    RespBody = jsone:encode(#{<<"error">> => <<"Internal server error">>}),
                    {500, RespBody, [{"Content-Type", "application/json"}]}
            end
    end.

%%%-------------------------------------------------------------------
%%% @private Parse request body robustly
%%% Supports:
%%% - JSON binary or string
%%% - form-urlencoded proplist
%%% - already parsed map
%%%-------------------------------------------------------------------
parse_body(Body) when is_map(Body) ->
    Body;
parse_body(Body) when is_list(Body), Body =/= [] ->
    case Body of
        [{_, _} | _] ->
            maps:from_list(Body);  %% form-urlencoded proplist
        _ ->
            try
                jsone:decode(list_to_binary(Body), [{object_format, map}])
            catch _:_ -> #{}
            end
    end;
parse_body(Body) when is_binary(Body) ->
    try
        jsone:decode(Body, [{object_format, map}])
    catch _:_ -> #{}
    end;
parse_body(_) -> #{}.

%%%-------------------------------------------------------------------
%%% @private Determine type of value
%%%-------------------------------------------------------------------
type_of(Val) when is_atom(Val) -> atom;
type_of(Val) when is_binary(Val) -> binary;
type_of(Val) when is_list(Val) -> list;
type_of(Val) when is_map(Val) -> map;
type_of(Val) when is_integer(Val) -> integer;
type_of(Val) when is_float(Val) -> float;
type_of(Val) when is_tuple(Val) -> tuple;
type_of(Val) when is_pid(Val) -> pid;
type_of(_) -> unknown.

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

