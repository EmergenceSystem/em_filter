%%%-------------------------------------------------------------------
%%% @doc
%%% Generic filter server using Wade HTTP server.
%%% Listens on a configurable port and delegates /query requests
%%% to a pluggable handler module.
%%% Handles JSON and form-urlencoded bodies robustly.
%%%-------------------------------------------------------------------

-module(em_filter_server).
-behaviour(gen_server).

-include_lib("wade/include/wade.hrl").

%% API exports
-export([start_link/3, wait_for_lock/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% State record
-record(filter_state, {
    filter_name :: atom(),
    handler_module :: module(),
    port :: integer(),
    wade_pid :: pid() | undefined
}).

%% ETS lock table name
-define(LOCK_TABLE, 'wade_lock').

%%%===================================================================
%%% API
%%%===================================================================

start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init({FilterName, HandlerModule, Port}) ->
    wait_for_lock(FilterName),
    process_flag(trap_exit, true),

    case wade:start_link(Port) of
        {ok, WadePid} ->
            %% Register /query route
            wade:route(post, "/query",
                fun(Req) -> handle_query(Req, HandlerModule) end, []),

            persistent_term:put({wade_pid, FilterName}, WadePid),

            FilterUrl = build_filter_url(Port) ++ "/query",
            io:format("Filter started at: ~s~n", [FilterUrl]),

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

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #filter_state{wade_pid=WadePid}=State) when Pid =:= WadePid ->
    io:format("Wade server crashed: ~p~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #filter_state{wade_pid=undefined}) -> ok;
terminate(_Reason, #filter_state{wade_pid=_WadePid, filter_name=FilterName}) ->
    catch wade:stop(),
    persistent_term:erase({wade_pid, FilterName}),
    ets:delete(?LOCK_TABLE, FilterName),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Waits for any existing lock to release
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("Waiting for previous instance to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.

%% Build base filter URL
build_filter_url(Port) ->
    "http://localhost:" ++ integer_to_list(Port).

%%===================================================================
%%% Handle /query requests
%%%===================================================================

handle_query(Req, HandlerModule) ->
    io:format("=== [HANDLE_QUERY START] ===~n"),
    RawBody = Req#req.body,
    io:format("[HANDLE_QUERY] Raw Body: ~p~n", [RawBody]),

    %% Parse body into map
    ParsedBody = parse_body(RawBody),
    io:format("[HANDLE_QUERY] ParsedBody: ~p~n", [ParsedBody]),

    %% Encode as JSON to pass to handler
    JsonBody = jsone:encode(ParsedBody),

    %% Call handler
    try
        Result = HandlerModule:handle(JsonBody),
        {200, Result, [
            {"Content-Type", "application/json"},
            {"Connection", "close"}
        ]}
    catch
        Error:Reason ->
            io:format("[HANDLE_QUERY ERROR] ~p:~p~n", [Error, Reason]),
            ErrBody = jsone:encode(#{<<"error">> => <<"Internal server error">>}),
            {500, ErrBody, [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

%%===================================================================
%%% Body Parsing
%%%===================================================================

parse_body(Body) when is_map(Body) ->
    %% Already parsed JSON
    Body;

parse_body(Body) when is_list(Body), length(Body) > 0 ->
    %% Could be form-urlencoded or raw JSON list
    case Body of
        [{K,_V}|_] when is_atom(K) orelse is_binary(K) ->
            %% form-urlencoded
            maps:from_list(Body);
        _ ->
            %% raw list, try to parse as JSON
            catch jsone:decode(list_to_binary(Body), [{object_format, map}])
    end;

parse_body(Body) when is_binary(Body) ->
    %% JSON binary
    catch jsone:decode(Body, [{object_format, map}]);

parse_body(_) ->
    %% fallback empty map
    #{}.

