%%%-------------------------------------------------------------------
%%% @doc
%%% Generic Filter Server using Wade HTTP server.
%%% Handles /query endpoint, parses incoming JSON or form bodies,
%%% delegates processing to a pluggable handler module.
%%%-------------------------------------------------------------------
-module(em_filter_server).
-behaviour(gen_server).

-include_lib("wade/include/wade.hrl").

%% API
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

%% ETS table for cross-process locks
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

terminate(_Reason, #filter_state{wade_pid = undefined}) ->
    ok;
terminate(_Reason, #filter_state{wade_pid = _WadePid, filter_name = FilterName}) ->
    io:format("Stopping Wade server...~n"),
    catch wade:stop(),
    persistent_term:erase({wade_pid, FilterName}),
    timer:sleep(500),
    ets:delete(?LOCK_TABLE, FilterName),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Public Helpers
%%%===================================================================

wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("Waiting for existing Wade instance to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.

get_filter_url(Port) ->
    BaseUrl = case embryo:read_emergence_conf() of
        undefined -> "http://localhost";
        Map ->
            case maps:get("em_disco", Map, #{}) of
                SubMap -> maps:get("filter_url", SubMap, "http://localhost")
            end
    end,
    BaseUrl ++ ":" ++ integer_to_list(Port).

%%%===================================================================
%%% Core Request Handling
%%%===================================================================

handle_query(Req, HandlerModule) ->
    io:format("=== [HANDLE_QUERY START] ===~n"),
    Body = Req#req.body,
    io:format("[HANDLE_QUERY] Raw Body: ~p~n", [Body]),

    ParsedBody = parse_body(Body),
    io:format("[HANDLE_QUERY] ParsedBody: ~p~n", [ParsedBody]),

    QueryValue = maps:get(<<"value">>, ParsedBody, maps:get(<<"query">>, ParsedBody, <<>>)),
    io:format("[HANDLE_QUERY] Final QueryValue: ~p~n", [QueryValue]),

    case QueryValue of
        <<>> ->
            RespBody = jsone:encode(#{<<"error">> => <<"Missing or empty query">>}),
            {400, RespBody, [{"Content-Type", "application/json"},{"Connection","close"}]};
        _ ->
            %% Encode map as JSON only once
            HandlerInput = jsone:encode(ParsedBody),
            try
                Result = HandlerModule:handle(HandlerInput),
                {200, Result, [{"Content-Type", "application/json"},{"Connection","close"}]}
            catch
                Error:Reason ->
                    io:format("[HANDLE_QUERY ERROR] ~p:~p~n", [Error, Reason]),
                    ErrResp = jsone:encode(#{<<"error">> => <<"Handler failed">>}),
                    {500, ErrResp, [{"Content-Type", "application/json"},{"Connection","close"}]}
            end
    end.

%%%===================================================================
%%% Internal Helpers
%%%===================================================================

parse_body(Body) when is_map(Body) ->
    %% Map body: convert all values to binaries if they are lists
    maps:map(
        fun(_K, V) ->
            case V of
                B when is_list(B) -> list_to_binary(B);
                B when is_binary(B) -> B;
                X -> X
            end
        end,
        Body
    );
parse_body(L) when is_list(L) ->
    %% Proplist (form-urlencoded) or JSON string
    case L of
        [] -> #{};
        [{K,_V}|_] when is_atom(K) orelse is_binary(K) ->
            %% Proplist -> map
            maps:from_list([{to_binary(K), to_binary(V)} || {_K,V} <- L]);
        _ ->
            %% Attempt JSON decode
            try jsone:decode(list_to_binary(L), [{object_format, map}]) of
                Map -> Map
            catch _:_ -> #{} end
    end;
parse_body(B) when is_binary(B) ->
    %% JSON string
    try jsone:decode(B, [{object_format, map}]) of
        Map -> Map
    catch _:_ -> #{} end;
parse_body(_) -> #{}.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).

