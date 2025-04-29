-module(em_filter_sup).
-behaviour(supervisor).

%% API
-export([start_link/3, stop/1]).

%% Supervisor callbacks
-export([init/1]).

%% ETS table for synchronization
-define(LOCK_TABLE, 'cowboy_lock').

%%====================================================================
%% API functions
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts the supervisor with a specific filter name, handler module,
%% and port.
%%
%% @param FilterName Name of the filter (atom)
%% @param HandlerModule Module to handle requests (module)
%% @param Port Port number for the HTTP service
%% @return {ok, Pid} if startup is successful
%% @end
%%--------------------------------------------------------------------
start_link(FilterName, HandlerModule, Port) ->
    SupName = list_to_atom(atom_to_list(FilterName) ++ "_sup"),
    supervisor:start_link({local, SupName}, ?MODULE, {FilterName, HandlerModule, Port}).

%%--------------------------------------------------------------------
%% @doc Stops the supervisor and its children.
%%
%% @param SupName Name of the supervisor (atom)
%% @end
%%--------------------------------------------------------------------
stop(SupName) ->
    supervisor:terminate_child(SupName, all),
    supervisor:delete_child(SupName, all),
    supervisor:stop(SupName).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Initializes the supervisor.
%%
%% @param {FilterName, HandlerModule, Port} Initialization arguments
%% @return {ok, {SupFlags, ChildSpecs}} Supervision configuration
%% @end
%%--------------------------------------------------------------------
init({FilterName, HandlerModule, Port}) ->
    %% Create ETS table for synchronization if it doesn't exist
    ets:new(?LOCK_TABLE, [named_table, public, set]),

    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),

    ChildSpecs = [
        #{
            id => ServerName,
            start => {em_filter_server, start_link, [FilterName, HandlerModule, Port]},
            restart => transient,
            shutdown => 5000,
            type => worker,
            modules => [em_filter_server]
        }
    ],

    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 30    % Increase period
    },

    %% Wait for the lock to be released before starting the child
    em_filter_server:wait_for_lock(FilterName),

    {ok, {SupFlags, ChildSpecs}}.

