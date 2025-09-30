-module(em_filter_server).
-behaviour(gen_server).

%% API
-export([start_link/3, wait_for_lock/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    filter_name :: atom(),
    handler_module :: module(),
    port :: integer(),
    wade_pid :: pid() | undefined
}).

%% ETS table for synchronization
-define(LOCK_TABLE, 'wade_lock').

%%====================================================================
%% API functions
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts the server process.
%%
%% @param FilterName Name of the filter
%% @param HandlerModule Module to handle requests
%% @param Port Port number for the HTTP service
%% @return {ok, Pid} if startup is successful
%% @end
%%--------------------------------------------------------------------
start_link(FilterName, HandlerModule, Port) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
    gen_server:start_link({local, ServerName}, ?MODULE, {FilterName, HandlerModule, Port}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Initializes the server.
%%
%% @param {FilterName, HandlerModule, Port} Initialization arguments
%% @return {ok, State} | {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init({FilterName, HandlerModule, Port}) ->
    %% Wait for the lock to be released
    wait_for_lock(FilterName),

    process_flag(trap_exit, true),  % Trap exit signals to handle termination

    %% Start Wade HTTP server
    case wade:start_link(Port) of
        {ok, WadePid} ->
            %% Setup route for the filter
            wade:route(post, "/query", 
                fun(Req) -> handle_query(Req, HandlerModule) end, 
                [], []),

            %% Store Wade PID for later reference
            persistent_term:put({wade_pid, FilterName}, WadePid),

            %% Register the filter with discovery service
            FilterUrl = get_filter_url(Port) ++ "/query",
            io:format("Filter started: ~s~n", [FilterUrl]),
            em_filter:register_filter(FilterUrl),

            {ok, #state{
                filter_name = FilterName,
                handler_module = HandlerModule,
                port = Port,
                wade_pid = WadePid
            }};
        {error, Reason} ->
            io:format("Failed to start Wade server: ~p~n", [Reason]),
            {stop, {wade_start_error, Reason}}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Handle the /query endpoint by delegating to the handler module.
%%--------------------------------------------------------------------
handle_query(Req, HandlerModule) ->
    try
        %% Get the request body
        Body = wade:body(Req, "query", ""),
        
        %% Call the handler module (assuming it has a handle/1 function)
        case erlang:function_exported(HandlerModule, handle, 1) of
            true ->
                Result = HandlerModule:handle(Body),
                {200, Result, [{"Content-Type", "application/json"}]};
            false ->
                {500, "Handler module does not export handle/1", 
                 [{"Content-Type", "text/plain"}]}
        end
    catch
        Error:Reason:Stack ->
            io:format("Error handling query: ~p:~p~n~p~n", [Error, Reason, Stack]),
            {500, "Internal server error", [{"Content-Type", "text/plain"}]}
    end.

-spec get_url_from_config(map() | undefined) -> string().
get_url_from_config(undefined) -> "http://localhost";
get_url_from_config(ConfigMap) ->
    case maps:get("em_disco", ConfigMap, undefined) of
        undefined -> "http://localhost";
        EmDisco ->
            maps:get("filter_url", EmDisco, "http://localhost")
    end.

-spec get_filter_url(integer()) -> string().
get_filter_url(Port) ->
    ConfigMap = embryo:read_emergence_conf(),
    BaseUrl = get_url_from_config(ConfigMap),
    BaseUrl ++ ":" ++ integer_to_list(Port).

%%--------------------------------------------------------------------
%% @private
%% @doc Handles call messages.
%%
%% @param Request The request term
%% @param From The caller reference
%% @param State The current state
%% @return {reply, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handles cast messages.
%%
%% @param Msg The message term
%% @param State The current state
%% @return {noreply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handles info messages.
%%
%% @param Info The info term
%% @param State The current state
%% @return {noreply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, #state{wade_pid = Pid} = State) ->
    io:format("Wade server crashed (~p), cleaning up...~n", [Reason]),
    {stop, {wade_crashed, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handles termination of the server.
%%
%% This function ensures that the Wade server is properly stopped
%% when the server terminates.
%%
%% @param Reason Termination reason
%% @param State Current state
%% @return ok
%% @end
%%--------------------------------------------------------------------
terminate(Reason, State) ->
    io:format("Terminating em_filter_server with reason: ~p~n", [Reason]),
    
    case State#state.wade_pid of
        undefined -> 
            ok;
        WadePid ->
            io:format("Stopping Wade server (PID: ~p)~n", [WadePid]),
            
            %% Set the lock to indicate Wade is stopping
            ets:insert(?LOCK_TABLE, {State#state.filter_name, true}),
            
            %% Stop Wade server
            catch wade:stop(),
            
            %% Clean up persistent term
            persistent_term:erase({wade_pid, State#state.filter_name}),
            
            %% Release the lock after a short delay to ensure Wade has stopped
            timer:sleep(500),
            ets:delete(?LOCK_TABLE, State#state.filter_name)
    end,
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Handles code changes.
%%
%% @param OldVsn Old version
%% @param State Current state
%% @param Extra Extra data
%% @return {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Waits for the lock to be released.
%%
%% @param FilterName Name of the filter
%% @end
%%--------------------------------------------------------------------
wait_for_lock(FilterName) ->
    case ets:lookup(?LOCK_TABLE, FilterName) of
        [] -> ok;
        _ ->
            io:format("Waiting for Wade to stop...~n"),
            timer:sleep(100),
            wait_for_lock(FilterName)
    end.
