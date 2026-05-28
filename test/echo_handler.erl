%%%-------------------------------------------------------------------
%%% @doc Minimal test handler — echoes the query back as a JSON list.
%%% Used only in Common Test suites.
%%% @end
%%%-------------------------------------------------------------------
-module(echo_handler).
-export([handle/2]).

%% Returns a JSON array containing one map: {"echo": "<query>"}.
%% Result is a binary (JSON-encoded), matching the real handler contract.
-spec handle(binary(), map()) -> {binary(), map()}.
handle(Query, Memory) ->
    Result = iolist_to_binary(json:encode([#{<<"echo">> => Query}])),
    {Result, Memory}.
