%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter Top-Level Supervisor
%%%
%%% Manages a dynamic pool of `em_filter_server' workers using a
%%% `simple_one_for_one' strategy.  Each worker represents one named
%%% filter (or agent) connected to an `em_disco' instance.
%%%
%%% Workers are started on demand via `start_filter/2' or
%%% `start_agent/3' and can be stopped individually via
%%% `stop_filter/1'.  A crashed worker is automatically restarted by
%%% the supervisor, which causes it to reconnect to `em_disco'.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_sup).
-behaviour(supervisor).

-export([start_link/0, start_filter/2, start_agent/3, stop_filter/1, init/1]).

%%--------------------------------------------------------------------
%% @doc Starts the supervisor and registers it locally.
%%
%% @return `{ok, Pid}' on success, `{error, Reason}' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc Starts a new plain filter worker under the supervisor.
%%
%% If a filter with the same name is already running, the existing
%% pid is returned without starting a duplicate.
%%
%% @param FilterName    Unique atom identifying the filter instance.
%% @param HandlerModule Module exporting `handle/1' that will process
%%                      queries received from `em_disco'.
%% @end
%%--------------------------------------------------------------------
-spec start_filter(atom(), module()) -> {ok, pid()} | {error, term()}.
start_filter(FilterName, HandlerModule) ->
    supervisor:start_child(?MODULE, [FilterName, HandlerModule]).

%%--------------------------------------------------------------------
%% @doc Starts a new agent worker under the supervisor.
%%
%% Identical to `start_filter/2' except that `Config' is forwarded to
%% `em_filter_server' to activate agent capabilities:
%%
%% <ul>
%%   <li>If `Config' contains `capabilities', an `agent_hello' frame
%%       is sent to `em_disco' after registration.</li>
%%   <li>If `Config' contains `{memory, ets}', a per-agent ETS table
%%       is created and `HandlerModule:handle/2' is called instead of
%%       `handle/1'.</li>
%% </ul>
%%
%% When `Config' is `#{}'  the behaviour is identical to
%% `start_filter/2'.
%%
%% @param AgentName     Unique atom identifying the agent instance.
%% @param HandlerModule Module exporting `handle/1' or `handle/2'.
%% @param Config        Agent options map (see `em_filter' module doc).
%% @end
%%--------------------------------------------------------------------
-spec start_agent(atom(), module(), map()) -> {ok, pid()} | {error, term()}.
start_agent(AgentName, HandlerModule, Config) ->
    supervisor:start_child(?MODULE, [AgentName, HandlerModule, Config]).

%%--------------------------------------------------------------------
%% @doc Stops a running filter or agent worker.
%%
%% @param FilterName Atom passed to `start_filter/2' or `start_agent/3'.
%% @end
%%--------------------------------------------------------------------
-spec stop_filter(atom()) -> ok | {error, term()}.
stop_filter(FilterName) ->
    ServerName = list_to_atom(atom_to_list(FilterName) ++ "_server"),
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
