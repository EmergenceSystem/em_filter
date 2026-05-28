-module(em_filter_query_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([valid_query_returns_200/1,
         bad_json_returns_400/1,
         missing_query_field_returns_400/1,
         query_port_embedded_in_gossip/1,
         handler_crash_returns_500/1]).

all() ->
    [valid_query_returns_200,
     bad_json_returns_400,
     missing_query_field_returns_400,
     query_port_embedded_in_gossip,
     handler_crash_returns_500].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    %% Start the em_filter application (which boots em_filter_sup and
    %% em_pop_sup).  If it is already running (e.g. another suite started
    %% it in the same CT session) ensure_all_started is a no-op.
    {ok, _} = application:ensure_all_started(em_filter),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    [{test_case, TestCase} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

%% POST /agent/query with a valid body returns 200 and {"results": [...]}.
valid_query_returns_200(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_echo, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],   %% disco not used
        query_port  => 19400,
        pop_port    => 19401,
        capabilities => [<<"echo">>]
    }),
    timer:sleep(150),   %% let the Cowboy listener bind
    Body    = <<"{\"query\": \"hello pop\"}">>,
    {ok, {{_, 200, _}, _, RespBin}} =
        httpc:request(post,
            {"http://localhost:19400/agent/query",
             [], "application/json", binary_to_list(Body)},
            [{timeout, 5000}], [{body_format, binary}]),
    #{<<"results">> := Results} = json:decode(RespBin),
    [#{<<"echo">> := <<"hello pop">>}] = Results,
    em_filter_sup:stop_agent(qtest_echo),
    ok.

%% Malformed JSON body -> 400.
bad_json_returns_400(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_bad1, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        query_port  => 19410
    }),
    timer:sleep(150),
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post,
            {"http://localhost:19410/agent/query",
             [], "application/json", "not valid json"},
            [{timeout, 5000}], []),
    em_filter_sup:stop_agent(qtest_bad1),
    ok.

%% Valid JSON but no "query" key -> 400.
missing_query_field_returns_400(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_bad2, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        query_port  => 19420
    }),
    timer:sleep(150),
    {ok, {{_, 400, _}, _, _}} =
        httpc:request(post,
            {"http://localhost:19420/agent/query",
             [], "application/json",
             "{\"text\": \"wrong key\"}"},
            [{timeout, 5000}], []),
    em_filter_sup:stop_agent(qtest_bad2),
    ok.

%% Handler crash -> 500
handler_crash_returns_500(_Config) ->
    {ok, _} = em_filter_sup:start_agent(qtest_crash, crash_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        query_port  => 19440
    }),
    timer:sleep(150),
    {ok, {{_, 500, _}, _, RespBin}} =
        httpc:request(post,
            {"http://localhost:19440/agent/query",
             [], "application/json", "{\"query\": \"boom\"}"},
            [{timeout, 5000}], [{body_format, binary}]),
    #{<<"error">> := _} = json:decode(RespBin),
    em_filter_sup:stop_agent(qtest_crash),
    ok.

%% query_port configured on a node appears in its gossip payload.
query_port_embedded_in_gossip(_Config) ->
    Vec  = em_filter_vec:from_capabilities([<<"echo">>]),
    {ok, Pid} = em_pop_node:start_link(#{
        port            => 19430,
        query_port      => 19431,
        vector          => Vec,
        gossip_interval => 0
    }),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    19431 = maps:get(<<"query_port">>, Payload),
    gen_server:stop(Pid),
    ok.
