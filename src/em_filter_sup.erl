%%%-------------------------------------------------------------------
%%% @doc
%%% `em_filter_sup' - Supervisor for Emergence filter services
%%%
%%% This module provides supervision for filter server processes.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_sup).
-behaviour(supervisor).

%% API
-export([start_link/3]).

%% Supervisor callbacks
-export([init/1]).

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
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),

    ChildSpecs = [
        #{
            id => ServerName,
            start => {em_filter_server, start_link, [FilterName, HandlerModule, Port]},
            restart => permanent,  % Ensure the server is restarted on failure
            shutdown => 5000,
            type => worker,
            modules => [em_filter_server]
        }
    ],

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    {ok, {SupFlags, ChildSpecs}}.

