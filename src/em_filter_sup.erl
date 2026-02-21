%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter Top-Level Supervisor
%%%
%%% Manages a dynamic pool of `em_filter_server' workers using a
%%% `simple_one_for_one' strategy.  Each worker represents one named
%%% filter connected to an `em_disco' instance.
%%%
%%% Workers are started on demand via `start_filter/2' and can be
%%% stopped individually via `stop_filter/1'.  A crashed worker is
%%% automatically restarted by the supervisor, which causes it to
%%% reconnect to `em_disco'.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_sup).
-behaviour(supervisor).

-export([start_link/0, start_filter/2, stop_filter/1, init/1]).

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
%% @doc Starts a new filter worker under the supervisor.
%%
%% If a filter with the same name is already running, the existing
%% pid is returned without starting a duplicate.
%%
%% @param FilterName    Unique atom identifying the filter instance.
%% @param HandlerModule Module exporting `handle/1' that will process
%%                      queries received from `em_disco'.
%% @return `{ok, Pid}' on success or if already started,
%%         `{error, Reason}' on failure.
%% @end
%%--------------------------------------------------------------------
-spec start_filter(atom(), module()) -> {ok, pid()} | {error, term()}.
start_filter(FilterName, HandlerModule) ->
    case supervisor:start_child(?MODULE, [FilterName, HandlerModule]) of
        {ok, Pid}                       -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason}                 -> {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc Stops the running filter identified by `FilterName'.
%%
%% Looks up the registered process name `<FilterName>_server' and
%% asks the supervisor to terminate it.
%%
%% @param FilterName Atom used when starting the filter.
%% @return `ok' on success, `{error, not_running}' if the filter is
%%         not currently active.
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
