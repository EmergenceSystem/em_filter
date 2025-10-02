%%%-------------------------------------------------------------------
%%% @doc
%%% Generic filter server using gen_server and Wade HTTP server.
%%% Provides /query endpoint and supports pluggable handler modules.
%%%
%%% Features:
%%% - Synchronization using ETS lock to prevent concurrent starts.
%%% - Handles JSON and form-urlencoded POST bodies seamlessly.
%%% - Delegates query handling to a user-defined module.
%%% - Graceful shutdown and error handling.
%%%-------------------------------------------------------------------
-module(em_filter_server).

-behaviour(gen_server).
-include_lib("wade/include/wade.hrl").

%% API
-export([start_link/3, wait_for_lock/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(filter_state, {
    filter_name :: atom(),
    handler_module :: module(),
    port :: integer(),
    wade_pid :: pid() | undefined
}).

-define(LOCK_TABLE, 'wade_lock').

%%%-------------------------------------------------------------------
%%% @doc Start the filter server
%%% @spec start_link(FilterName :: atom(), HandlerModule :: module(), Port :: integer()) -> {ok, pid()} | {error, any()}
%%%-------------------------------------------------------------------
start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%%-------------------------------------------------------------------
%%% @doc gen_server init callback
%%% Starts Wade HTTP server, registers /query route, registers filter URL.
%%%-------------------------------------------------------------------
init({FilterName, HandlerModule, Port}) ->
    wait_for_lock(FilterName),
    process_flag(trap_exit, true),

    case wade:start_link(Port) of
        {ok, WadePid} ->
            io:format("[INIT] Registering /query route~n"),
            wade:route(post, "/query",
                fun(Req) -> handle_query(Req, HandlerModule) end, []),

            persistent_term:put({wade_pid, FilterName}, WadePid),

            FilterUrl = get_filter_url(Port) ++ "/query",
            io:format("[INIT] Filter started: ~s~n", [FilterUrl]),
            em_filter:register_filter(FilterUrl),

            {ok, #filter_state{
                filter_name = FilterName,
                handler_module = HandlerModule,
                port = Port,
                wade_pid = WadePid
            }};
        {error, Reason} ->
            io:format("[ERROR] Failed to start Wade server: ~p~n", [Reason]),
            {stop, {wade_start_error, Reason}}
    end.

%%%-------------------------------------------------------------------
%%% @doc Handle incoming /query requests
%%% Supports JSON and form-urlencoded POST bodies.
%%% Delegates actual handling to HandlerModule:handle(QueryValue)
%%%-------------------------------------------------------------------
handle_query(Req, HandlerModule) ->
    io:format("=== [HANDLE_QUERY START] ===~n"),
    Body = Req#req.body,
    io:format("[HANDLE_QUERY] Raw Body: ~p (type: ~p)~n", [Body, type_of(Body)]),

    %% Convert body to map
    ParsedBody =
        case Body of
            M when is_map(M) -> M;
            L when is_list(L), length(L) > 0 ->
                case L of
                    [{K,_}|_] when is_atom(K) orelse is_binary(K) -> maps:from_list(L);
                    _ -> % fallback for unexpected list
                        case catch jsone:decode(list_to_binary(L), [{object_format, map}]) of
                            {'EXIT', _} -> #{};
                            Map -> Map
                        end
                end;
            B when is_binary(B) ->
                case catch jsone:decode(B, [{object_format, map}]) of
                    {'EXIT', _} -> #{};
                    Map -> Map
                end;
            _ -> #{}
        end,

    %% Extract query value with key normalization (JSON binary keys or atom keys)
    QueryValue =
        case ParsedBody of
            MapData when is_map(MapData) ->
                case maps:get(<<"value">>, MapData, undefined) of
                    undefined ->
                        case maps:get(value, MapData, undefined) of
                            undefined ->
                                case maps:get(<<"query">>, MapData, undefined) of
                                    undefined -> maps:get(query, MapData, <<>>);
                                    V -> V
                                end;
                            V -> V
                        end;
                    V -> V
                end;
            _ -> <<>>
        end,

    io:format("[HANDLE_QUERY] Final QueryValue: ~p~n", [QueryValue]),

    case QueryValue of
        <<>> ->
            RespBody = jsone:encode(#{<<"error">> => <<"Missing or empty body">>}),
            {400, RespBody, [{"Content-Type", "application/json"}, {"Connection", "close"}]};
        _ ->
            Result = HandlerModule:handle(QueryValue),
            {200, Result, [{"Content-Type", "application/json"}, {"Connection", "close"}]}
    end.

%%%-------------------------------------------------------------------
%%% @private
%%% Return type as atom for logging
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
%%% @private
%%% Build full filter URL (e.g., http://localhost:8081)
%%%-------------------------------------------------------------------
get_filter_url(Port) ->
    BaseUrl = "http://localhost",
    BaseUrl ++ ":" ++ integer_to_list(Port).

%%%-------------------------------------------------------------------
%%% gen_server callbacks
%%%-------------------------------------------------------------------
handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #filter_state{wade_pid = WadePid} = State) when Pid =:= WadePid ->
    io:format("[INFO] Wade server crashed: ~p~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};
handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, State) ->
    io:format("[TERMINATE] Reason: ~p~n", [Reason]),
    case State#filter_state.wade_pid of
        undefined -> ok;
        _WadePid ->
            catch wade:stop(),
            persistent_term:erase({wade_pid, State#filter_state.filter_name}),
            ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%-------------------------------------------------------------------
%%% @doc Wait for ETS lock to be free
%%%-------------------------------------------------------------------
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("[WAIT] Waiting for Wade to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.

