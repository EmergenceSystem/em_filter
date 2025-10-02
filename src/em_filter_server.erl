%%%-------------------------------------------------------------------
%%% @doc
%%% This module implements a generic filter server using gen_server.
%%% It starts an HTTP server (Wade) on a configurable port and exposes
%%% a /query endpoint. Incoming requests are parsed and delegated to a
%%% pluggable handler module that must implement handle/1.
%%%
%%% The server supports:
%%% - JSON or form-urlencoded POST bodies
%%% - ETS-based synchronization to prevent concurrent filter starts
%%% - Robust error handling and logging
%%% - Automatic registration to a discovery service
%%%-------------------------------------------------------------------

-module(em_filter_server).

-behaviour(gen_server).

-include_lib("wade/include/wade.hrl").

%% API exports
-export([start_link/3, wait_for_lock/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record storing filter info and Wade PID
-record(filter_state, {
    filter_name :: atom(),
    handler_module :: module(),
    port :: integer(),
    wade_pid :: pid() | undefined
}).

%% ETS table for synchronization lock
-define(LOCK_TABLE, 'wade_lock').

%%%===================================================================
%%% API
%%%===================================================================

%% Starts the filter server with given name, handler module, and port
-spec start_link(atom(), module(), integer()) -> {ok, pid()} | {error, any()}.
start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init({FilterName, HandlerModule, Port}) ->
    %% Wait for any existing lock
    wait_for_lock(FilterName),
    process_flag(trap_exit, true),

    %% Start Wade HTTP server
    case wade:start_link(Port) of
        {ok, WadePid} ->
            %% Register /query route
            io:format("[INIT] Registering /query route~n"),
            wade:route(post, "/query",
                fun(Req) ->
                    handle_query(Req, HandlerModule)
                end, []),

            %% Persist Wade PID
            persistent_term:put({wade_pid, FilterName}, WadePid),

            %% Register filter in discovery
            FilterUrl = get_filter_url(Port) ++ "/query",
            io:format("Filter started: ~s~n", [FilterUrl]),
            em_filter:register_filter(FilterUrl),

            {ok, #filter_state{
                filter_name = FilterName,
                handler_module = HandlerModule,
                port = Port,
                wade_pid = WadePid
            }};
        {error, Reason} ->
            io:format("Failed to start Wade server: ~p~n", [Reason]),
            {stop, {wade_start_error, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #filter_state{wade_pid = WadePid} = State) when Pid =:= WadePid ->
    io:format("Wade server crashed (~p), cleaning up...~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    io:format("Terminating em_filter_server with reason: ~p~n", [Reason]),
    case State#filter_state.wade_pid of
        undefined -> ok;
        _WadePid ->
            io:format("Stopping Wade server (PID: ~p)~n", [_WadePid]),
            ets:insert(?LOCK_TABLE, {State#filter_state.filter_name, true}),
            catch wade:stop(),
            persistent_term:erase({wade_pid, State#filter_state.filter_name}),
            timer:sleep(500),
            ets:delete(?LOCK_TABLE, State#filter_state.filter_name)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% Wait recursively for filter lock
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("Waiting for Wade to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.

%% Get base filter URL from config
-spec get_url_from_config(map() | undefined) -> string().
get_url_from_config(undefined) -> "http://localhost";
get_url_from_config(Map) ->
    maps:get("filter_url", maps:get("em_disco", Map, #{}), "http://localhost").

%% Build full URL for filter
-spec get_filter_url(integer()) -> string().
get_filter_url(Port) ->
    ConfigMap = embryo:read_emergence_conf(),
    BaseUrl = get_url_from_config(ConfigMap),
    BaseUrl ++ ":" ++ integer_to_list(Port).

%%%-------------------------------------------------------------------
%%% @doc
%%% Handles /query requests and delegates to handler_module:handle/1
%%% Supports JSON maps and form-urlencoded bodies
%%%-------------------------------------------------------------------
handle_query(Req, HandlerModule) ->
    io:format("=== [HANDLE_QUERY START] ===~n"),
    try
        Body = Req#req.body,
        io:format("[HANDLE_QUERY] Raw Body: ~p (type: ~p)~n", [Body, type_of(Body)]),

        %% Normalize body to a map
        ParsedBody = case Body of
            M when is_map(M) ->
                M; % JSON already parsed by Wade
            L when is_list(L), length(L) > 0 ->
                case L of
                    [{K, _V} | _] when is_atom(K) orelse is_binary(K) ->
                        maps:from_list(L); % form-urlencoded
                    _ ->
                        try jsone:decode(list_to_binary(L), [{object_format, map}]) catch _:_ -> #{} end
                end;
            [] -> #{}; % empty body
            B when is_binary(B) ->
                try jsone:decode(B, [{object_format, map}]) catch _:_ -> #{} end;
            _ -> #{}
        end,

        %% Extract query value
        QueryValue = case ParsedBody of
            Map when is_map(Map) ->
                case maps:get(<<"value">>, Map, undefined) of
                    undefined -> maps:get(<<"query">>, Map, <<>>);
                    Val -> Val
                end;
            _ -> <<>>
        end,

        io:format("[HANDLE_QUERY] Final QueryValue: ~p~n", [QueryValue]),

        %% Return 400 if query is empty
        case QueryValue of
            <<>> ->
                RespBody = jsone:encode(#{<<"error">> => <<"Missing or empty body">>}),
                {400, RespBody, [{"Content-Type", "application/json"}, {"Connection", "close"}]};
            _ ->
                Result = HandlerModule:handle(QueryValue),
                {200, Result, [{"Content-Type", "application/json"}, {"Connection", "close"}]}
        end
    catch
        Error:Reason:Stacktrace ->
            io:format("[HANDLE_QUERY ERROR] ~p:~p~nStack: ~p~n", [Error, Reason, Stacktrace]),
            ErrResp = jsone:encode(#{<<"error">> => <<"Internal server error">>}),
            {500, ErrResp, [{"Content-Type", "application/json"}, {"Connection", "close"}]}
    end.

%%%-------------------------------------------------------------------
%%% @private
%%% Utility: get type of a value for debugging
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

