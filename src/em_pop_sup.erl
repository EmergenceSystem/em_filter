%%%-------------------------------------------------------------------
%%% @doc
%%% em_pop_sup — Supervisor for Population Protocol nodes
%%%
%%% One em_pop node (em_pop_node gen_server + Cowboy listener) is
%%% started per agent that includes a `pop_port' key in its Config map.
%%%
%%% === ETS registry ===
%%%
%%% An ETS table named `em_pop_agent_nodes' maps:
%%%
%%%   AgentName (atom) → PopNodePid (pid)
%%%
%%% The table is `public' with `read_concurrency' so that
%%% `em_filter:pop_peers/1' and friends can do O(1) lookups without
%%% going through a gen_server call.
%%%
%%% The table is created inside `start_link/0' with an existence check,
%%% so supervisor restarts (which would call `start_link/0' again) do
%%% not crash on a duplicate table name.
%%%
%%% === Restart strategy ===
%%%
%%% `simple_one_for_one' — each dynamically added child is an
%%% independent em_pop_node.  Restart is `transient': a node that exits
%%% normally (e.g. via `stop_node/1') is not restarted, but an
%%% unexpected crash will trigger a restart.
%%%
%%% This supervisor is started as a permanent child of em_filter_sup
%%% at application boot, before any agent workers are created.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_sup).
-behaviour(supervisor).

-export([start_link/0, start_node/2, stop_node/1, get_node/1, init/1]).

%% Name of the ETS table used as the AgentName → Pid registry.
-define(TABLE, em_pop_agent_nodes).

%%--------------------------------------------------------------------
%% @doc Start the supervisor and create the ETS registry if needed.
%%
%% The ETS table is created here rather than in `init/1' because
%% `init/1' runs inside the new supervisor process, whereas we want the
%% table to be owned by the calling process (the application master)
%% so it survives supervisor crashes and restarts.
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    %% Guard against duplicate table on supervisor restart.
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [set, named_table, public,
                             {read_concurrency, true}]);
        _ ->
            %% Table already exists (e.g. supervisor restarted) — reuse it.
            ok
    end,
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc Start an em_pop node for AgentName with the given Opts map.
%%
%% Delegates to `supervisor:start_child/2' and registers the resulting
%% pid in the ETS registry so it can be found quickly by name.
%%
%% Opts must contain at least:
%%   `port'   => pos_integer()  — TCP port for the gossip HTTP listener
%%   `vector' => binary()       — f32 capability vector (unit norm)
%%
%% Optional keys:
%%   `stale_timeout'   => pos_integer()     — default 30 000 ms
%%   `gossip_interval' => non_neg_integer() — default  5 000 ms
%%   `max_peers'       => pos_integer()     — default 200
%% @end
%%--------------------------------------------------------------------
-spec start_node(atom(), map()) -> {ok, pid()} | {error, term()}.
start_node(AgentName, Opts) ->
    case supervisor:start_child(?MODULE, [Opts]) of
        {ok, Pid} ->
            %% Register the new pid under the agent's name for fast lookup.
            ets:insert(?TABLE, {AgentName, Pid}),
            {ok, Pid};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc Stop the em_pop node for AgentName.
%%
%% Removes the entry from the ETS registry and terminates the child
%% process.  No-op if AgentName has no registered node.
%%
%% The child's `restart => transient' strategy ensures the supervisor
%% does not try to restart it after a normal termination.
%% @end
%%--------------------------------------------------------------------
-spec stop_node(atom()) -> ok.
stop_node(AgentName) ->
    case ets:lookup(?TABLE, AgentName) of
        [{_, Pid}] ->
            %% Remove from registry before terminating to prevent a
            %% race where get_node/1 returns a pid that is about to die.
            ets:delete(?TABLE, AgentName),
            supervisor:terminate_child(?MODULE, Pid),
            ok;
        [] ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc Return the em_pop node pid for AgentName, or `undefined'.
%%
%% O(1) ETS lookup — safe to call from any process at any time.
%% @end
%%--------------------------------------------------------------------
-spec get_node(atom()) -> pid() | undefined.
get_node(AgentName) ->
    case ets:lookup(?TABLE, AgentName) of
        [{_, Pid}] -> Pid;
        []         -> undefined
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Supervisor child specification template.
%%
%% `simple_one_for_one' means the child spec below is a template:
%% `start_node/2' appends `[Opts]' to the empty arg list, resulting in
%% a call to `em_pop_node:start_link(Opts)'.
%%
%% `restart => transient' means:
%%   • Normal exit (stop_node/1 → supervisor shutdown) → no restart.
%%   • Abnormal exit (crash)                           → restart.
%% @end
%%--------------------------------------------------------------------
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Child = #{
        id       => em_pop_node,       %% template id (overridden per instance)
        start    => {em_pop_node, start_link, []},
        restart  => transient,         %% do not restart intentional stops
        shutdown => 5000,              %% ms to wait for clean shutdown
        type     => worker,
        modules  => [em_pop_node]
    },
    {ok, {#{strategy  => simple_one_for_one,
            intensity => 5,            %% max 5 restarts …
            period    => 10},          %% … in any 10-second window
          [Child]}}.
