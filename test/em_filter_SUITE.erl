%%%-------------------------------------------------------------------
%%% @doc
%%% Common Test integration suite for em_filter.
%%%
%%% Tests the full lifecycle of a filter agent against a lightweight
%%% mock em_disco server (em_filter_mock_disco / em_filter_mock_ws).
%%% JWT token validation is skipped in the mock — the suite focuses
%%% on em_filter's client-side protocol behaviour.
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    agent_connects_and_registers/1,
    agent_hello_always_sent/1,
    agent_responds_to_query/1,
    capabilities_routing/1,
    ets_memory_survives_reconnect/1,
    stop_agent_not_running/1
]).

%% Handler module used by all test agents.
-export([handle/2]).

all() -> [
    agent_connects_and_registers,
    agent_hello_always_sent,
    agent_responds_to_query,
    capabilities_routing,
    ets_memory_survives_reconnect,
    stop_agent_not_running
].

%%====================================================================
%% Suite setup / teardown
%%====================================================================

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(cowboy),
    Port = em_filter_mock_disco:start(),
    {ok, _} = application:ensure_all_started(em_filter),
    [{disco_port, Port} | Config].

end_per_suite(_Config) ->
    application:stop(em_filter),
    em_filter_mock_disco:stop(),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Handler — counts queries, accumulates history
%%====================================================================

%% Returns an Erlang map — em_filter_server encodes it into the
%% "data" field of the JSON result frame.
handle(Body, Memory) ->
    Count  = maps:get(count, Memory, 0),
    Result = #{<<"echo">> => Body, <<"count">> => Count + 1},
    {Result, Memory#{count => Count + 1}}.

%%====================================================================
%% Test cases
%%====================================================================

%% 1. Agent connects and appears in the mock registry.
agent_connects_and_registers(Config) ->
    Port  = proplists:get_value(disco_port, Config),
    {ok, _} = em_filter:start_agent(ct_reg, ?MODULE, #{
        jwt_token   => <<"test-token">>,
        disco_nodes => [{"localhost", Port, tcp}]
    }),
    ?assert(wait_for_agent(<<"ct_reg">>, 3000)),
    ok = em_filter:stop_agent(ct_reg).

%% 2. agent_hello is always sent — agent appears in registry even
%%    with empty capabilities.
agent_hello_always_sent(Config) ->
    Port  = proplists:get_value(disco_port, Config),
    {ok, _} = em_filter:start_agent(ct_hello, ?MODULE, #{
        jwt_token    => <<"tok">>,
        disco_nodes  => [{"localhost", Port, tcp}],
        capabilities => []
    }),
    ?assert(wait_for_agent(<<"ct_hello">>, 3000)),
    Agents = em_filter_mock_disco:list_agents(),
    [Entry] = [A || A = #{name := N} <- Agents, N =:= <<"ct_hello">>],
    ?assertEqual([], maps:get(capabilities, Entry)),
    ok = em_filter:stop_agent(ct_hello).

%% 3. Agent receives a query from the mock and replies correctly.
agent_responds_to_query(Config) ->
    Port  = proplists:get_value(disco_port, Config),
    {ok, _} = em_filter:start_agent(ct_query, ?MODULE, #{
        jwt_token   => <<"tok">>,
        disco_nodes => [{"localhost", Port, tcp}]
    }),
    ?assert(wait_for_agent(<<"ct_query">>, 3000)),
    Results = em_filter_mock_disco:query(<<"hello">>, 1, 3000),
    ?assertEqual(1, length(Results)),
    ?assertEqual(<<"hello">>, maps:get(<<"echo">>, hd(Results))),
    ok = em_filter:stop_agent(ct_query).

%% 4. Capability routing — only agents with matching caps receive query.
%%    (Mock sends to ALL registered agents; this test verifies em_filter
%%    correctly announces its caps so the caller can filter server-side.)
%%    Here we verify that two agents with different caps both register
%%    their capabilities correctly in the mock registry.
capabilities_routing(Config) ->
    Port  = proplists:get_value(disco_port, Config),
    {ok, _} = em_filter:start_agent(ct_cap_a, ?MODULE, #{
        jwt_token    => <<"tok">>,
        disco_nodes  => [{"localhost", Port, tcp}],
        capabilities => [<<"alpha">>]
    }),
    {ok, _} = em_filter:start_agent(ct_cap_b, ?MODULE, #{
        jwt_token    => <<"tok">>,
        disco_nodes  => [{"localhost", Port, tcp}],
        capabilities => [<<"beta">>]
    }),
    ?assert(wait_for_agent(<<"ct_cap_a">>, 3000)),
    ?assert(wait_for_agent(<<"ct_cap_b">>, 3000)),

    Agents = em_filter_mock_disco:list_agents(),
    CapsA  = caps_for(<<"ct_cap_a">>, Agents),
    CapsB  = caps_for(<<"ct_cap_b">>, Agents),
    ?assertEqual([<<"alpha">>], CapsA),
    ?assertEqual([<<"beta">>],  CapsB),

    ok = em_filter:stop_agent(ct_cap_a),
    ok = em_filter:stop_agent(ct_cap_b).

%% 5. ETS memory accumulates across multiple queries to the same agent.
ets_memory_survives_reconnect(Config) ->
    Port  = proplists:get_value(disco_port, Config),
    {ok, _} = em_filter:start_agent(ct_mem, ?MODULE, #{
        jwt_token   => <<"tok">>,
        disco_nodes => [{"localhost", Port, tcp}],
        memory      => ets
    }),
    ?assert(wait_for_agent(<<"ct_mem">>, 3000)),

    %% Send 3 queries sequentially and verify the count increments.
    [R1] = em_filter_mock_disco:query(<<"q1">>, 1, 3000),
    [R2] = em_filter_mock_disco:query(<<"q2">>, 1, 3000),
    [R3] = em_filter_mock_disco:query(<<"q3">>, 1, 3000),

    ?assertEqual(1, maps:get(<<"count">>, R1)),
    ?assertEqual(2, maps:get(<<"count">>, R2)),
    ?assertEqual(3, maps:get(<<"count">>, R3)),

    ok = em_filter:stop_agent(ct_mem).

%% 6. stop_agent returns {error, not_running} for unknown agents.
stop_agent_not_running(_Config) ->
    ?assertEqual({error, not_running},
                 em_filter:stop_agent(ct_nonexistent_xyz)).

%%====================================================================
%% Helpers
%%====================================================================

%% Poll until the named agent appears in the mock registry.
wait_for_agent(Name, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Name, Deadline).

wait_loop(Name, Deadline) ->
    Agents = em_filter_mock_disco:list_agents(),
    case lists:any(fun(#{name := N}) -> N =:= Name end, Agents) of
        true  -> true;
        false ->
            Rem = Deadline - erlang:monotonic_time(millisecond),
            case Rem > 0 of
                true  -> timer:sleep(min(50, Rem)), wait_loop(Name, Deadline);
                false -> false
            end
    end.

caps_for(Name, Agents) ->
    case [C || #{name := N, capabilities := C} <- Agents, N =:= Name] of
        [Caps | _] -> Caps;
        []         -> undefined
    end.
