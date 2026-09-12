-module(em_filter_mcp_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([tools_list_names_tool_after_agent/1,
         tools_call_echoes_query/1,
         tools_call_unknown_tool_errors/1,
         tools_call_missing_query_errors/1]).

%% NOTE: mirrors em_filter_query_SUITE — full em_filter app started once,
%% one agent per test case on its own mcp_port to avoid cross-test
%% interference.
all() ->
    [tools_list_names_tool_after_agent,
     tools_call_echoes_query,
     tools_call_unknown_tool_errors,
     tools_call_missing_query_errors].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(em_filter),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

mcp_post(Port, Body) ->
    {ok, {{_, 200, _}, _, RespBin}} =
        httpc:request(post,
            {"http://localhost:" ++ integer_to_list(Port) ++ "/mcp",
             [], "application/json",
             binary_to_list(iolist_to_binary(json:encode(Body)))},
            [{timeout, 5000}], [{body_format, binary}]),
    json:decode(RespBin).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

tools_list_names_tool_after_agent(_Config) ->
    {ok, _} = em_filter_sup:start_agent(mcptest_list, echo_handler, #{
        disco_nodes  => [{"localhost", 29999, tcp}],
        mcp_port     => 19500,
        capabilities => [<<"echo">>]
    }),
    timer:sleep(150),
    Resp = mcp_post(19500, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                              <<"method">> => <<"tools/list">>}),
    #{<<"result">> := #{<<"tools">> := [Tool]}} = Resp,
    #{<<"name">> := <<"mcptest_list">>} = Tool,
    em_filter_sup:stop_agent(mcptest_list),
    ok.

tools_call_echoes_query(_Config) ->
    {ok, _} = em_filter_sup:start_agent(mcptest_echo, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        mcp_port    => 19510
    }),
    timer:sleep(150),
    Resp = mcp_post(19510, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                              <<"method">> => <<"tools/call">>,
                              <<"params">> => #{
                                  <<"name">> => <<"mcptest_echo">>,
                                  <<"arguments">> => #{<<"query">> => <<"hello mcp">>}
                              }}),
    #{<<"result">> := #{<<"content">> := [#{<<"text">> := Text}]}} = Resp,
    [#{<<"echo">> := <<"hello mcp">>}] = json:decode(Text),
    em_filter_sup:stop_agent(mcptest_echo),
    ok.

tools_call_unknown_tool_errors(_Config) ->
    {ok, _} = em_filter_sup:start_agent(mcptest_unknown, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        mcp_port    => 19520
    }),
    timer:sleep(150),
    Resp = mcp_post(19520, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
                              <<"method">> => <<"tools/call">>,
                              <<"params">> => #{<<"name">> => <<"nope">>}}),
    #{<<"error">> := #{<<"code">> := -32601}} = Resp,
    em_filter_sup:stop_agent(mcptest_unknown),
    ok.

tools_call_missing_query_errors(_Config) ->
    {ok, _} = em_filter_sup:start_agent(mcptest_missing, echo_handler, #{
        disco_nodes => [{"localhost", 29999, tcp}],
        mcp_port    => 19530
    }),
    timer:sleep(150),
    Resp = mcp_post(19530, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4,
                              <<"method">> => <<"tools/call">>,
                              <<"params">> => #{
                                  <<"name">> => <<"mcptest_missing">>,
                                  <<"arguments">> => #{}
                              }}),
    #{<<"error">> := #{<<"code">> := -32602}} = Resp,
    em_filter_sup:stop_agent(mcptest_missing),
    ok.
