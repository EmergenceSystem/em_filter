-module(em_filter_sup).
-behaviour(supervisor).

%% API
-export([start_link/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link(FilterName, HandlerModule, Port, Options) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_sup"),
    supervisor:start_link({local, ServerName}, ?MODULE, {HandlerModule, Port, Options}).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init({HandlerModule, Port, Options}) ->
    {ok, {
        {one_for_one, 5, 10},
        [
            {
                HandlerModule,
                {em_filter_server, start_link, [HandlerModule, Port, Options]},
                permanent,
                5000,
                worker,
                [HandlerModule]
            }
        ]
    }}.
