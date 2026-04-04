%%%-------------------------------------------------------------------
%%% @doc
%%% Minimal em_disco mock for Common Test integration tests.
%%%
%%% A gen_server owns the ETS tables so they survive for the full
%%% suite lifetime regardless of which process calls start/0.
%%%
%%% Starts a Cowboy WebSocket listener that implements the em_disco
%%% agent handshake protocol:
%%%
%%%   Agent → Mock: {"action":"register",    "name":"<n>"}
%%%   Agent → Mock: {"action":"agent_hello", "capabilities":[...]}
%%%   Mock  → Agent: {"action":"query",      "id":"<id>","body":"<b>"}
%%%   Agent → Mock: {"action":"result",      "id":"<id>","data":<d>}
%%%
%%% JWT token validation is intentionally omitted — any token value
%%% (or no token) is accepted.
%%%
%%% == Usage ==
%%%
%%%   Port = em_filter_mock_disco:start(),
%%%   % … run em_filter agents pointing to {"localhost", Port, tcp} …
%%%   Results = em_filter_mock_disco:query(<<"hello">>, 1, 2000),
%%%   em_filter_mock_disco:stop().
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_mock_disco).
-behaviour(gen_server).

-export([start/0, stop/0, port/0, list_agents/0, query/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(LISTENER, mock_disco_listener).
-define(AGENTS,   mock_disco_agents).
-define(QUERIES,  mock_disco_queries).

%%====================================================================
%% Public API
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts the mock disco server. Returns the listening port.
%% @end
%%--------------------------------------------------------------------
-spec start() -> inet:port_number().
start() ->
    {ok, _} = gen_server:start({local, ?MODULE}, ?MODULE, [], []),
    gen_server:call(?MODULE, port).

%%--------------------------------------------------------------------
%% @doc Stops the mock disco server and cleans up.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%%--------------------------------------------------------------------
%% @doc Returns the port the mock is listening on.
%% @end
%%--------------------------------------------------------------------
-spec port() -> inet:port_number().
port() ->
    ranch:get_port(?LISTENER).

%%--------------------------------------------------------------------
%% @doc Returns all currently registered agents.
%% @end
%%--------------------------------------------------------------------
-spec list_agents() -> [map()].
list_agents() ->
    [#{name => Name, capabilities => Caps}
     || {Name, Caps, _Pid} <- ets:tab2list(?AGENTS)].

%%--------------------------------------------------------------------
%% @doc Sends a query to all registered agents and collects results.
%%
%% Waits up to `TimeoutMs' milliseconds for `ExpectedCount' results.
%% @end
%%--------------------------------------------------------------------
-spec query(binary(), non_neg_integer(), pos_integer()) -> [term()].
query(Body, ExpectedCount, TimeoutMs) ->
    Id      = base64:encode(crypto:strong_rand_bytes(8)),
    Payload = json:encode(#{
        <<"action">> => <<"query">>,
        <<"id">>     => Id,
        <<"body">>   => Body
    }),
    ets:insert(?QUERIES, {Id, self()}),
    lists:foreach(fun({_Name, _Caps, Pid}) ->
        Pid ! {send, Payload}
    end, ets:tab2list(?AGENTS)),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    collect(ExpectedCount, Id, Deadline, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?AGENTS,  [set, named_table, public]),
    ets:new(?QUERIES, [set, named_table, public]),
    Dispatch = cowboy_router:compile([
        {'_', [{"/ws", em_filter_mock_ws, []}]}
    ]),
    {ok, _} = cowboy:start_clear(?LISTENER,
        [{port, 0}],
        #{env => #{dispatch => Dispatch}}),
    {ok, #{}}.

handle_call(port, _From, State) ->
    {reply, ranch:get_port(?LISTENER), State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    cowboy:stop_listener(?LISTENER),
    catch ets:delete(?AGENTS),
    catch ets:delete(?QUERIES),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

collect(0, Id, _Deadline, Acc) ->
    ets:delete(?QUERIES, Id),
    Acc;
collect(N, Id, Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {query_result, Id, Result} ->
            collect(N - 1, Id, Deadline, [Result | Acc])
    after Remaining ->
        ets:delete(?QUERIES, Id),
        Acc
    end.
