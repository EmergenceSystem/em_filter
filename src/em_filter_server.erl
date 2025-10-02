%%% @doc
%%% This module implements a generic filter server based on the gen_server behaviour.
%%% It manages starting an HTTP server (using Wade) that listens on a configurable port
%%% and provides a /query endpoint for incoming requests.
%%%
%%% The filter server synchronizes access using an ETS-based lock system to prevent
%%% multiple instances of the same filter starting concurrently.
%%%
%%% Incoming HTTP requests are delegated to a pluggable handler module that must export a handle/1 function.
%%% This separation allows different filter logic to be plugged without modifying the server infrastructure.
%%%
%%% The module includes robust error handling, detailed logging, and graceful shutdown procedures
%%% to ensure reliability in production.
%%% It also integrates with a discovery service for runtime registration of filter URLs.
%%%
%%% State stored in the process includes:
%%%  - filter_name: Atom identifying the filter
%%%  - handler_module: Module handling query processing
%%%  - port: TCP port number for HTTP server
%%%  - wade_pid: PID of the Wade HTTP server process
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

%% ETS table name used for synchronization lock across filter instances
-define(LOCK_TABLE, 'wade_lock').

%%% @doc
%%% Starts the filter server process with given name, handler module, and HTTP port.
%%% Registers the process locally using a derived name to avoid conflicts.
%%%
start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%% @doc
%%% Initializes the server by:
%%% 1. Waiting for any existing lock on the filter to be released (prevents concurrent starts)
%%% 2. Starting the Wade HTTP server on the configured port
%%% 3. Registering an HTTP route /query that delegates to local handle_query/2
%%% 4. Registering filter service URL to a discovery mechanism
%%% 5. Setting up internal process state
%%%
%%% Returns {ok, State} if successful, otherwise stops the server.
%%%
init({FilterName, HandlerModule, Port}) ->
    wait_for_lock(FilterName),
    process_flag(trap_exit, true),

    case wade:start_link(Port) of
        {ok, WadePid} ->
            wade:route(post, "/query",
                fun(Req) -> handle_query(Req, HandlerModule) end,
                [], []),

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

%%% @doc
%%% Parses incoming HTTP request body robustly and delegates to handler_module:handle/1.
%%% Supports body as map, binary (JSON string), or list (string).
%%%
%%% Handles empty bodies explicitly by returning 400 error.
%%% Catches all exceptions to prevent server crash and returns HTTP 500 with error message.
%%%
handle_query(Req, HandlerModule) ->
    io:format("~n=== [HANDLE_QUERY START] ===~n"),
    io:format("[HANDLE_QUERY] HandlerModule: ~p~n", [HandlerModule]),
    
    try
        %% Extract body from req record (Wade already parses it)
        Body = Req#req.body,
        io:format("[HANDLE_QUERY] Body type: ~p, value: ~p~n", [type_of(Body), Body]),
        
        %% Extract the query value from body (same logic as em_disco_handlers)
        QueryValue = case Body of
            M when is_map(M) ->
                io:format("[HANDLE_QUERY] Body is map with keys: ~p~n", [maps:keys(M)]),
                case maps:get(<<"value">>, M, undefined) of
                    undefined -> 
                        QV = maps:get(<<"query">>, M, <<>>),
                        io:format("[HANDLE_QUERY] Using 'query' key: ~p~n", [QV]),
                        QV;
                    V -> 
                        io:format("[HANDLE_QUERY] Using 'value' key: ~p~n", [V]),
                        V
                end;
            B when is_binary(B) -> 
                io:format("[HANDLE_QUERY] Body is binary: ~p~n", [B]),
                B;
            B when is_list(B) -> 
                BinValue = list_to_binary(B),
                io:format("[HANDLE_QUERY] Body converted from list to binary: ~p~n", [BinValue]),
                BinValue;
            _ -> 
                io:format("[HANDLE_QUERY] Body is other type, using empty binary~n"),
                <<>>
        end,
        
        io:format("[HANDLE_QUERY] Final QueryValue: ~p~n", [QueryValue]),
        
        case QueryValue of
            <<>> ->
                io:format("[HANDLE_QUERY] Empty query value, returning 400~n"),
                ResponseBody = jsone:encode(#{<<"error">> => <<"Missing or empty body">>}),
                {400, ResponseBody, [
                    {"Content-Type", "application/json"},
                    {"Connection", "close"}
                ]};
            _ ->
                io:format("[HANDLE_QUERY] Calling ~p:handle(~p)~n", [HandlerModule, QueryValue]),
                Result = HandlerModule:handle(QueryValue),
                io:format("[HANDLE_QUERY] Handler returned: ~p~n", [Result]),
                
                {200, Result, [
                    {"Content-Type", "application/json"},
                    {"Connection", "close"}
                ]}
        end
    catch
        Error:Reason:Stacktrace ->
            io:format("~n=== [HANDLE_QUERY ERROR] ===~n"),
            io:format("[ERROR] ~p:~p~n", [Error, Reason]),
            io:format("[ERROR] Stacktrace: ~p~n", [Stacktrace]),
            io:format("[ERROR] HandlerModule: ~p~n", [HandlerModule]),
            
            ResponseBody1 = jsone:encode(#{<<"error">> => <<"Internal server error">>}),
            {500, ResponseBody1, [
                {"Content-Type", "application/json"},
                {"Connection", "close"}
            ]}
    end.

%%% @private
%%% Helper function to determine the type of a value
type_of(Val) when is_atom(Val) -> atom;
type_of(Val) when is_binary(Val) -> binary;
type_of(Val) when is_list(Val) -> list;
type_of(Val) when is_map(Val) -> map;
type_of(Val) when is_integer(Val) -> integer;
type_of(Val) when is_float(Val) -> float;
type_of(Val) when is_tuple(Val) -> tuple;
type_of(Val) when is_pid(Val) -> pid;
type_of(_) -> unknown.

%%% @private
%%% Utility function returning the configured base URL or default localhost
-spec get_url_from_config(map() | undefined) -> string().
get_url_from_config(undefined) -> "http://localhost";
get_url_from_config(ConfigMap) ->
    case maps:get("em_disco", ConfigMap, undefined) of
        undefined -> "http://localhost";
        EmDisco ->
            maps:get("filter_url", EmDisco, "http://localhost")
    end.

%%% @private
%%% Utility function building full URL combining base URL and port
-spec get_filter_url(integer()) -> string().
get_filter_url(Port) ->
    ConfigMap = embryo:read_emergence_conf(),
    BaseUrl = get_url_from_config(ConfigMap),
    BaseUrl ++ ":" ++ integer_to_list(Port).

%%% @doc
%%% Handles gen_server call requests; here simply replies :ok as no calls are handled
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%% @doc
%%% Handles asynchronous gen_server cast messages; no specific processing done
handle_cast(_Msg, State) ->
    {noreply, State}.

%%% @doc
%%% Handles info messages, notably traps exit signals from Wade to cleanup
handle_info({'EXIT', Pid, Reason}, #filter_state{wade_pid = WadePid} = State) when Pid =:= WadePid ->
    io:format("Wade server crashed (~p), cleaning up...~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%% @doc
%%% Gracefully terminates the filter server by stopping Wade server,
%%% cleaning persistent state, and releasing the synchronization lock.
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

%%% @doc
%%% Handles code upgrades; currently simply preserves state without changes.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% @doc
%%% Waits recursively for a lock on the filter to be released before proceeding.
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("Waiting for Wade to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.
