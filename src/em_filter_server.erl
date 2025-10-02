%%%-------------------------------------------------------------------
%%% @doc
%%% Filter server based on gen_server.
%%% - Starts a Wade HTTP server on a configurable port.
%%% - Provides a /query endpoint.
%%% - Ensures only one instance per filter using an ETS lock table.
%%% - Delegates request processing to a pluggable handler module.
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

%% ETS table used as lock to prevent multiple filter instances
-define(LOCK_TABLE, 'wade_lock').

%%%-------------------------------------------------------------------
%%% @doc
%%% Starts the filter server
%%%-------------------------------------------------------------------
start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%%-------------------------------------------------------------------
%%% @doc
%%% Initializes server:
%%% - Waits for lock
%%% - Starts Wade server
%%% - Registers /query route
%%% - Registers filter URL
%%%-------------------------------------------------------------------
init({FilterName, HandlerModule, Port}) ->
    wait_for_lock(FilterName),
    process_flag(trap_exit, true),

    case wade:start_link(Port) of
        {ok, WadePid} ->
            %% Register /query route
            wade:route(post, "/query",
                fun(Req) -> handle_query(Req, HandlerModule) end, []),

            %% Store Wade PID
            persistent_term:put({wade_pid, FilterName}, WadePid),

            %% Register filter URL
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

%%%-------------------------------------------------------------------
%%% @doc
%%% Parses incoming HTTP body robustly and delegates to handler_module:handle/1
%%% - Supports JSON (binary map) or form-urlencoded (proplist)
%%% - Always converts body to map before passing to handler
%%%-------------------------------------------------------------------
handle_query(Req, HandlerModule) ->
    io:format("=== [HANDLE_QUERY START] ===~n"),
    Body = Req#req.body,
    io:format("[HANDLE_QUERY] Raw Body: ~p (type: ~p)~n", [Body, type_of(Body)]),

    %% Normalize body to map
    ParsedBody =
        case Body of
            M when is_map(M) ->
                M;  %% JSON already parsed
            L when is_list(L), length(L) > 0 ->
                case L of
                    [{K,_}|_] when is_atom(K) orelse is_binary(K) ->
                        maps:from_list(L);  %% form-urlencoded
                    _ ->
                        %% Try decode JSON string
                        try jsone:decode(list_to_binary(L), [{object_format, map}])
                        catch _:_ -> #{} end
                end;
            B when is_binary(B) ->
                try jsone:decode(B, [{object_format, map}])
                catch _:_ -> #{} end;
            _ -> #{}
        end,

    io:format("[HANDLE_QUERY] ParsedBody: ~p~n", [ParsedBody]),

    %% Call handler module with map
    try
        Result = HandlerModule:handle(ParsedBody),
        {200, Result, [{"Content-Type", "application/json"}, {"Connection", "close"}]}
    catch
        Error:Reason ->
            io:format("[HANDLE_QUERY ERROR] ~p:~p~n", [Error, Reason]),
            ErrRespBody = jsone:encode(#{<<"error">> => <<"Internal server error">>}),
            {500, ErrRespBody, [{"Content-Type", "application/json"}, {"Connection", "close"}]}
    end.

%%%-------------------------------------------------------------------
%%% @private
%%% Returns type of a value
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
%%% Builds filter URL using port and optional config
%%%-------------------------------------------------------------------
-spec get_filter_url(integer()) -> string().
%%%-------------------------------------------------------------------
%%% @private
%%% Builds filter URL using port and optional config
%%%-------------------------------------------------------------------
get_filter_url(Port) ->
    BaseUrl =
        case embryo:read_emergence_conf() of
            undefined -> "http://localhost";
            Map ->
                EmDisco = maps:get("em_disco", Map, #{}),
                maps:get("filter_url", EmDisco, "http://localhost")
        end,
    BaseUrl ++ ":" ++ integer_to_list(Port).

%%%-------------------------------------------------------------------
%%% @doc
%%% Handles synchronous gen_server calls
%%%-------------------------------------------------------------------
handle_call(_Request, _From, State) -> {reply, ok, State}.

%%%-------------------------------------------------------------------
%%% @doc
%%% Handles asynchronous casts
%%%-------------------------------------------------------------------
handle_cast(_Msg, State) -> {noreply, State}.

%%%-------------------------------------------------------------------
%%% @doc
%%% Handles exit signals from Wade server
%%%-------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, #filter_state{wade_pid = WadePid} = State) when Pid =:= WadePid ->
    io:format("Wade server crashed (~p), cleaning up...~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};
handle_info(_Info, State) -> {noreply, State}.

%%%-------------------------------------------------------------------
%%% @doc
%%% Gracefully terminates the server and Wade process
%%%-------------------------------------------------------------------
terminate(Reason, State) ->
    io:format("Terminating em_filter_server: ~p~n", [Reason]),
    case State#filter_state.wade_pid of
        undefined -> ok;
        WadePid ->
            io:format("Stopping Wade server (PID: ~p)~n", [WadePid]),
            catch wade:stop(),
            persistent_term:erase({wade_pid, State#filter_state.filter_name})
    end,
    ok.

%%%-------------------------------------------------------------------
%%% @doc
%%% Handles code upgrades
%%%-------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%-------------------------------------------------------------------
%%% @doc
%%% Waits for ETS lock to be released
%%%-------------------------------------------------------------------
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ -> timer:sleep(100), wait_for_lock(FilterName)
    end.

