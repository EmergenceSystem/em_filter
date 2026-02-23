%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter Top-Level Supervisor
%%%
%%% Manages a dynamic pool of `em_filter_server' agent workers using a
%%% `simple_one_for_one' strategy. Each worker represents one named
%%% agent connected to an em_disco instance.
%%%
%%% A crashed worker is restarted automatically, reconnecting the
%%% agent to em_disco.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_sup).
-behaviour(supervisor).

-export([start_link/0, start_agent/3, stop_agent/1, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc Starts a new agent worker under the supervisor.
%%
%% @param AgentName     Unique atom identifying the agent.
%% @param HandlerModule Module exporting `handle/2'.
%% @param Config        Agent options map (capabilities, memory).
%% @end
%%--------------------------------------------------------------------
-spec start_agent(atom(), module(), map()) -> {ok, pid()} | {error, term()}.
start_agent(AgentName, HandlerModule, Config) ->
    supervisor:start_child(?MODULE, [AgentName, HandlerModule, Config]).

%%--------------------------------------------------------------------
%% @doc Stops a running agent worker.
%%
%% @param AgentName Atom passed to `start_agent/3'.
%% @end
%%--------------------------------------------------------------------
-spec stop_agent(atom()) -> ok | {error, term()}.
stop_agent(AgentName) ->
    ServerName = list_to_atom(atom_to_list(AgentName) ++ "_server"),
    case whereis(ServerName) of
        undefined -> {error, not_running};
        Pid       -> supervisor:terminate_child(?MODULE, Pid)
    end.

%% @private
init([]) ->
    Child = #{
        id       => em_filter_server,
        start    => {em_filter_server, start_link, []},
        restart  => permanent,
        shutdown => 5000,
        type     => worker,
        modules  => [em_filter_server]
    },
    {ok, {#{strategy  => simple_one_for_one,
            intensity => 10,
            period    => 60},
          [Child]}}.
