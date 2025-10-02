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
    io:format("[START_LINK] FilterName=~p, HandlerModule=~p, Port=~p~n", [FilterName, HandlerModule, Port]),
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    io:format("[START_LINK] Derived ServerName=~p~n", [ServerName]),
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
    io:format("[INIT] Starting initialization for FilterName=~p~n", [FilterName]),
    io:format("[INIT] HandlerModule=~p, Port=~p~n", [HandlerModule, Port]),
    
    wait_for_lock(FilterName),
    io:format("[INIT] Lock acquired for ~p~n", [FilterName]),

    process_flag(trap_exit, true),
    io:format("[INIT] Trap exit flag set~n"),

    io:format("[INIT] Attempting to start Wade on port ~p~n", [Port]),
    case wade:start_link(Port) of
        {ok, WadePid} ->
            io:format("[INIT] Wade started successfully with PID=~p~n", [WadePid]),
            
            %% Setup HTTP POST /query route with injected handler module
            io:format("[INIT] Registering route /query with HandlerModule=~p~n", [HandlerModule]),
            wade:route(post, "/query",
                fun(Req) -> handle_query(Req, HandlerModule) end,
                [], []),
            io:format("[INIT] Route registered successfully~n"),

            persistent_term:put({wade_pid, FilterName}, WadePid),
            io:format("[INIT] Wade PID stored in persistent_term~n"),

            %% Compose full filter URL and register service dynamically
            FilterUrl = get_filter_url(Port) ++ "/query",
            io:format("[INIT] Filter URL composed: ~s~n", [FilterUrl]),
            em_filter:register_filter(FilterUrl),
            io:format("[INIT] Filter registered with discovery service~n"),

            io:format("[INIT] Initialization complete for ~p~n", [FilterName]),
            {ok, #filter_state{
                filter_name = FilterName,
                handler_module = HandlerModule,
                port = Port,
                wade_pid = WadePid
            }};
        {error, Reason} ->
            io:format("[INIT ERROR] Failed to start Wade server: ~p~n", [Reason]),
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
    io:format("[HANDLE_QUERY] Request received~n"),
    io:format("[HANDLE_QUERY] Req type: ~p~n", [element(1, Req)]),
    io:format("[HANDLE_QUERY] HandlerModule: ~p~n", [HandlerModule]),
    io:format("[HANDLE_QUERY] HandlerModule type: ~p~n", [is_atom(HandlerModule)]),
    
    try
        io:format("[HANDLE_QUERY] Calling wade:body/1~n"),
        Body = wade:body(Req),
        io:format("[HANDLE_QUERY] Body received, type: ~p~n", [type_of(Body)]),
        io:format("[HANDLE_QUERY] Body value: ~p~n", [Body]),
        io:format("[HANDLE_QUERY] Body size: ~p~n", [
            case Body of
                B when is_binary(B) -> byte_size(B);
                B when is_list(B) -> length(B);
                B when is_map(B) -> map_size(B);
                _ -> unknown
            end
        ]),
        
        io:format("[HANDLE_QUERY] Extracting QueryValue from body~n"),
        QueryValue = case Body of
            M when is_map(M) ->
                io:format("[HANDLE_QUERY] Body is a map with keys: ~p~n", [maps:keys(M)]),
                case maps:get(<<"value">>, M, undefined) of
                    undefined -> 
                        io:format("[HANDLE_QUERY] 'value' key not found, trying 'query' key~n"),
                        maps:get(<<"query">>, M, undefined);
                    V -> 
                        io:format("[HANDLE_QUERY] Found 'value' key: ~p~n", [V]),
                        V
                end;
            [] -> 
                io:format("[HANDLE_QUERY] Body is empty list~n"),
                undefined;
            _ -> 
                io:format("[HANDLE_QUERY] Body is neither map nor empty list, using as-is~n"),
                Body
        end,
        
        io:format("[HANDLE_QUERY] QueryValue extracted: ~p~n", [QueryValue]),
        io:format("[HANDLE_QUERY] QueryValue type: ~p~n", [type_of(QueryValue)]),
        
        case QueryValue of
            Val when Val =:= undefined; Val =:= <<>> ->
                io:format("[HANDLE_QUERY] QueryValue is undefined or empty~n"),
                RespBody = jsone:encode(#{<<"error">> => <<"Missing or empty body">>}),
                Req2 = wade:reply(Req, 400, #{"content-type" => "application/json"}, RespBody),
                io:format("[HANDLE_QUERY] Sent 400 response~n"),
                {Req2, Req2#req.reply_status};
            _ ->
                io:format("[HANDLE_QUERY] QueryValue is valid, proceeding with handler~n"),
                io:format("[HANDLE_QUERY] Checking if module ~p is loaded~n", [HandlerModule]),
                
                %% Check if module is loaded
                case code:is_loaded(HandlerModule) of
                    {file, LoadedFrom} ->
                        io:format("[HANDLE_QUERY] Module ~p is loaded from: ~p~n", [HandlerModule, LoadedFrom]);
                    false ->
                        io:format("[HANDLE_QUERY WARNING] Module ~p is NOT loaded! Attempting to load...~n", [HandlerModule]),
                        case code:load_file(HandlerModule) of
                            {module, HandlerModule} ->
                                io:format("[HANDLE_QUERY] Module ~p loaded successfully~n", [HandlerModule]);
                            {error, LoadError} ->
                                io:format("[HANDLE_QUERY ERROR] Failed to load module ~p: ~p~n", [HandlerModule, LoadError])
                        end
                end,
                
                %% List all exported functions
                io:format("[HANDLE_QUERY] Listing all exports from ~p:~n", [HandlerModule]),
                try
                    Exports = HandlerModule:module_info(exports),
                    io:format("[HANDLE_QUERY] Exports: ~p~n", [Exports])
                catch
                    E1:R1 ->
                        io:format("[HANDLE_QUERY ERROR] Could not get module_info: ~p:~p~n", [E1, R1])
                end,
                
                %% Check for handle/1 function
                io:format("[HANDLE_QUERY] Checking if ~p:handle/1 is exported~n", [HandlerModule]),
                case erlang:function_exported(HandlerModule, handle, 1) of
                    true ->
                        io:format("[HANDLE_QUERY] ~p:handle/1 is exported~n", [HandlerModule]),
                        io:format("[HANDLE_QUERY] About to call ~p:handle(~p)~n", [HandlerModule, QueryValue]),
                        
                        try
                            Result = HandlerModule:handle(QueryValue),
                            io:format("[HANDLE_QUERY] Handler returned successfully~n"),
                            io:format("[HANDLE_QUERY] Result type: ~p~n", [type_of(Result)]),
                            io:format("[HANDLE_QUERY] Result value: ~p~n", [Result]),
                            
                            RespBody = Result,
                            Req2 = wade:reply(Req, 200, #{"content-type" => "application/json"}, RespBody),
                            io:format("[HANDLE_QUERY] Sent 200 response~n"),
                            {Req2, Req2#req.reply_status}
                        catch
                            HandlerError:HandlerReason:HandlerStacktrace ->
                                io:format("[HANDLE_QUERY ERROR] Exception in handler call:~n"),
                                io:format("  Error: ~p~n", [HandlerError]),
                                io:format("  Reason: ~p~n", [HandlerReason]),
                                io:format("  Stacktrace: ~p~n", [HandlerStacktrace]),
                                io:format("  Module: ~p~n", [HandlerModule]),
                                io:format("  Function: handle/1~n"),
                                io:format("  Argument: ~p~n", [QueryValue]),
                                
                                ErrorMsg = io_lib:format("Handler error: ~p:~p", [HandlerError, HandlerReason]),
                                RespBody1 = jsone:encode(#{<<"error">> => list_to_binary(ErrorMsg)}),
                                Req21 = wade:reply(Req, 500, #{"content-type" => "application/json"}, RespBody1),
                                {Req21, Req21#req.reply_status}
                        end;
                    false ->
                        io:format("[HANDLE_QUERY ERROR] ~p:handle/1 is NOT exported~n", [HandlerModule]),
                        io:format("[HANDLE_QUERY ERROR] Module ~p does not export handle/1 function~n", [HandlerModule]),
                        RespBody = jsone:encode(#{<<"error">> => <<"Handler module missing handle/1">>}),
                        Req2 = wade:reply(Req, 500, #{"content-type" => "application/json"}, RespBody),
                        {Req2, Req2#req.reply_status}
                end
        end
    catch
        Error:Reason:Stacktrace ->
            io:format("~n=== [HANDLE_QUERY ERROR] ===~n"),
            io:format("[ERROR] Error type: ~p~n", [Error]),
            io:format("[ERROR] Reason: ~p~n", [Reason]),
            io:format("[ERROR] Stacktrace: ~p~n", [Stacktrace]),
            io:format("[ERROR] HandlerModule: ~p~n", [HandlerModule]),
            io:format("[ERROR] Request: ~p~n", [Req]),
            
            %% Additional diagnostic info for undef errors
            case Error of
                error when Reason =:= undef ->
                    io:format("[ERROR] UNDEF error detected - function does not exist~n"),
                    case Stacktrace of
                        [{Mod, Fun, Args, _Info} | _] ->
                            io:format("[ERROR] Failed call: ~p:~p with args: ~p~n", [Mod, Fun, Args]);
                        _ ->
                            io:format("[ERROR] Could not extract call details from stacktrace~n")
                    end;
                _ ->
                    ok
            end,
            
            ResponseBody = jsone:encode(#{<<"error">> => <<"Internal server error">>}),
            Req3 = wade:reply(Req, 500, #{"content-type" => "application/json"}, ResponseBody),
            io:format("=== [HANDLE_QUERY END] ===~n~n"),
            {Req3, Req3#req.reply_status}
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
    io:format("[INFO] Wade server crashed (PID: ~p, Reason: ~p), cleaning up...~n", [Pid, Reason]),
    {stop, {wade_crashed, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%% @doc
%%% Gracefully terminates the filter server by stopping Wade server,
%%% cleaning persistent state, and releasing the synchronization lock.
terminate(Reason, State) ->
    io:format("[TERMINATE] Terminating em_filter_server with reason: ~p~n", [Reason]),
    case State#filter_state.wade_pid of
        undefined -> 
            io:format("[TERMINATE] No Wade PID to clean up~n"),
            ok;
        _WadePid ->
            io:format("[TERMINATE] Stopping Wade server (PID: ~p)~n", [_WadePid]),
            ets:insert(?LOCK_TABLE, {State#filter_state.filter_name, true}),
            catch wade:stop(),
            persistent_term:erase({wade_pid, State#filter_state.filter_name}),
            timer:sleep(500),
            ets:delete(?LOCK_TABLE, State#filter_state.filter_name),
            io:format("[TERMINATE] Wade cleanup complete~n")
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
        [] -> 
            io:format("[WAIT_FOR_LOCK] No lock found for ~p~n", [FilterName]),
            ok;
        _ ->
            io:format("[WAIT_FOR_LOCK] Waiting for Wade to stop for ~p...~n", [FilterName]),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.
