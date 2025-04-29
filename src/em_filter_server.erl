-module(em_filter_server).
-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    filter_name :: atom(),
    handler_module :: module(),
    port :: integer(),
    cowboy_ref :: atom()
}).

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
    process_flag(trap_exit, true),  % Trap exit signals to handle termination

    % Start application dependencies
    {ok, _} = application:ensure_all_started(cowboy),

    % Setup Cowboy routes
    Dispatch = cowboy_router:compile([
        {'_', [{"/query", HandlerModule, []}]}
    ]),

    % Start Cowboy with unique reference name for this filter
    CowboyRef = list_to_atom(atom_to_list(FilterName) ++ "_http"),
    case cowboy:start_clear(CowboyRef, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            % Store cowboy reference for later stopping
            persistent_term:put({cowboy_ref, FilterName}, CowboyRef),

            % Register the filter with discovery service
            FilterUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/query",
            io:format("Filter started: ~s~n", [FilterUrl]),
            em_filter:register_filter(FilterUrl),

            {ok, #state{
                filter_name = FilterName,
                handler_module = HandlerModule,
                port = Port,
                cowboy_ref = CowboyRef
            }};
        {error, Reason} ->
            {stop, {cowboy_start_error, Reason}}
    end.

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
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handles termination of the server.
%%
%% This function ensures that the Cowboy listener is properly stopped
%% when the server terminates.
%%
%% @param Reason Termination reason
%% @param State Current state
%% @return ok
%% @end
%%--------------------------------------------------------------------
terminate(Reason, State) ->
    io:format("Terminating with reason: ~p~n", [Reason]),
    % Arrêter le listener Cowboy en utilisant la référence stockée dans l'état
    case State#state.cowboy_ref of
        undefined -> ok;
        CowboyRef ->
            io:format("Stopping Cowboy listener: ~p~n", [CowboyRef]),
            ok = cowboy:stop_listener(CowboyRef)
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

