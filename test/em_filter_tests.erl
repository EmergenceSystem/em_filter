-module(em_filter_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exported so they can be passed as handler module to em_filter_server.
-export([handle/2]).

%% ===================================================================
%% Inline handler — agent contract only
%% ===================================================================

%% Agent handler with memory — counts queries and accumulates bodies.
handle(Body, Memory) ->
    Count   = maps:get(count,   Memory, 0),
    History = maps:get(history, Memory, []),
    Result  = json:encode(#{
        <<"echo">>  => Body,
        <<"count">> => Count + 1
    }),
    {Result, Memory#{count => Count + 1, history => [Body | History]}}.

%% ===================================================================
%% Helpers
%% ===================================================================

start_app() ->
    application:ensure_all_started(em_filter).

stop_app(_) ->
    application:stop(em_filter).

safe_stop(Name) ->
    case em_filter:stop_agent(Name) of
        ok                   -> ok;
        {error, not_running} -> ok
    end.

%% ===================================================================
%% Suite: start_agent/3 — minimal config (replaces old start_filter)
%% ===================================================================

start_stop_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 {ok, Pid} = em_filter:start_agent(test_filter, ?MODULE, #{}),
                 ?assert(is_pid(Pid)),
                 ok = em_filter:stop_agent(test_filter)
             end)
         ]
     end}.

%% ===================================================================
%% Suite: start_agent/3 — no memory, no capabilities
%% ===================================================================

agent_no_config_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 %% Empty config — minimal agent.
                 {ok, Pid} = em_filter:start_agent(agent_plain, ?MODULE, #{}),
                 ?assert(is_pid(Pid)),
                 safe_stop(agent_plain)
             end),
             ?_test(begin
                 %% Server process must be registered under <n>_server.
                 {ok, _} = em_filter:start_agent(agent_named, ?MODULE, #{}),
                 ?assert(is_pid(whereis(agent_named_server))),
                 safe_stop(agent_named)
             end)
         ]
     end}.

%% ===================================================================
%% Suite: start_agent/3 — capabilities, no memory
%% ===================================================================

agent_capabilities_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 {ok, Pid} = em_filter:start_agent(agent_caps, ?MODULE, #{
                     capabilities => [<<"test">>, <<"echo">>]
                 }),
                 ?assert(is_pid(Pid)),
                 safe_stop(agent_caps)
             end),
             ?_test(begin
                 %% Capabilities only — no memory key — ETS table must NOT exist.
                 {ok, _} = em_filter:start_agent(agent_caps2, ?MODULE, #{
                     capabilities => [<<"cap_a">>]
                 }),
                 ?assertEqual(undefined, ets:info(agent_caps2_memory)),
                 safe_stop(agent_caps2)
             end),
             ?_test(begin
                 %% Empty capabilities list — valid, no agent_hello sent.
                 {ok, Pid} = em_filter:start_agent(agent_empty_caps, ?MODULE, #{
                     capabilities => []
                 }),
                 ?assert(is_pid(Pid)),
                 safe_stop(agent_empty_caps)
             end)
         ]
     end}.

%% ===================================================================
%% Suite: start_agent/3 — memory => ram (default, no ETS table)
%% ===================================================================

agent_memory_ram_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 {ok, _} = em_filter:start_agent(agent_no_mem, ?MODULE, #{
                     memory => ram
                 }),
                 %% ETS table must NOT be created.
                 ?assertEqual(undefined, ets:info(agent_no_mem_memory)),
                 safe_stop(agent_no_mem)
             end)
         ]
     end}.

%% ===================================================================
%% Suite: start_agent/3 — memory => ets
%% ===================================================================

agent_memory_ets_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 %% ETS table must be created on start.
                 {ok, _} = em_filter:start_agent(agent_mem, ?MODULE, #{
                     memory => ets
                 }),
                 ?assertNotEqual(undefined, ets:info(agent_mem_memory)),
                 safe_stop(agent_mem)
             end),
             ?_test(begin
                 %% Table must be initially empty (no entry before first query).
                 {ok, _} = em_filter:start_agent(agent_mem2, ?MODULE, #{
                     memory => ets
                 }),
                 ?assertEqual([], ets:tab2list(agent_mem2_memory)),
                 safe_stop(agent_mem2)
             end),
             ?_test(begin
                 %% Table must be deleted when the agent is stopped.
                 {ok, _} = em_filter:start_agent(agent_mem3, ?MODULE, #{
                     memory => ets
                 }),
                 ok = safe_stop(agent_mem3),
                 timer:sleep(100),
                 ?assertEqual(undefined, ets:info(agent_mem3_memory))
             end)
         ]
     end}.

%% ===================================================================
%% Suite: handle/2 logic — memory accumulates correctly
%%
%% The ETS table is `protected' (owned by the server process).
%% The test process cannot write to it.  We verify the handler
%% logic in pure isolation — no ETS involved here.
%% ETS lifecycle (create/delete) is covered in agent_memory_ets_test_.
%% ===================================================================

agent_memory_persistence_test_() ->
    [
        ?_test(begin
            %% Three successive calls must give count = 3.
            FinalMem = lists:foldl(fun(I, Mem) ->
                {_Result, NewMem} = ?MODULE:handle(integer_to_binary(I), Mem),
                NewMem
            end, #{}, [1, 2, 3]),
            ?assertEqual(3, maps:get(count,   FinalMem)),
            ?assertEqual(3, length(maps:get(history, FinalMem, [])))
        end),
        ?_test(begin
            %% Each call increments count by exactly 1.
            {_, Mem1} = ?MODULE:handle(<<"a">>, #{}),
            {_, Mem2} = ?MODULE:handle(<<"b">>, Mem1),
            ?assertEqual(1, maps:get(count, Mem1)),
            ?assertEqual(2, maps:get(count, Mem2))
        end),
        ?_test(begin
            %% History grows newest-first.
            {_, Mem1} = ?MODULE:handle(<<"first">>,  #{}),
            {_, Mem2} = ?MODULE:handle(<<"second">>, Mem1),
            [Second, First | _] = maps:get(history, Mem2),
            ?assertEqual(<<"second">>, Second),
            ?assertEqual(<<"first">>,  First)
        end)
    ].

%% ===================================================================
%% Suite: stop_agent/1 works correctly
%% ===================================================================

stop_works_for_agents_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 {ok, _} = em_filter:start_agent(agent_stop, ?MODULE, #{
                     capabilities => [<<"x">>],
                     memory       => ets
                 }),
                 ?assert(is_pid(whereis(agent_stop_server))),
                 ok = em_filter:stop_agent(agent_stop),
                 timer:sleep(100),
                 ?assertEqual(undefined, whereis(agent_stop_server))
             end),
             ?_test(begin
                 %% Stopping a non-existent agent must return an error,
                 %% not crash.
                 ?assertEqual({error, not_running},
                              em_filter:stop_agent(ghost_agent))
             end)
         ]
     end}.

%% ===================================================================
%% Suite: start_agent/3 — combined capabilities + memory
%% ===================================================================

agent_full_config_test_() ->
    {setup,
     fun start_app/0,
     fun stop_app/1,
     fun(_) ->
         [
             ?_test(begin
                 {ok, Pid} = em_filter:start_agent(agent_full, ?MODULE, #{
                     capabilities => [<<"summarize">>, <<"llm">>, <<"translate">>],
                     memory       => ets
                 }),
                 ?assert(is_pid(Pid)),
                 ?assert(is_pid(whereis(agent_full_server))),
                 ?assertNotEqual(undefined, ets:info(agent_full_memory)),
                 safe_stop(agent_full)
             end)
         ]
     end}.
