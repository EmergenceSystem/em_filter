%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter_http — Cowboy handler for the direct agent query endpoint.
%%%
%%% Route: POST /agent/query
%%%
%%% This handler is the network entry point for Emquest's em_pop-based
%%% direct dispatch.  When Emquest finds this agent via kvex similarity
%%% search and decides to query it directly, the HTTP request lands here.
%%%
%%% Request body (JSON):
%%% ```
%%% {"query": "user query text"}
%%% '''
%%%
%%% Success response — HTTP 200:
%%% ```
%%% {"results": [... agent handler output ...]}
%%% '''
%%%
%%% where `<agent handler output>' is whatever `handler:handle/2' returns
%%% (a JSON-encoded binary), decoded once so it is properly nested in
%%% the response JSON rather than appearing as an escaped string.
%%%
%%% Error responses:
%%%   400 — malformed JSON or missing "query" field
%%%   500 — internal handler error or gen_server call timeout
%%%
%%% The Cowboy route options map MUST contain:
%%%   `server' => atom()  — registered name of the em_filter_server
%%%                          (always `<agent>_server' for index 1)
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_http).
-behaviour(cowboy_handler).
-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Handle one POST /agent/query request.
%%
%% Reads the full body, extracts the "query" field, calls the local
%% agent gen_server synchronously (30 s timeout), and returns the
%% result as JSON.
%%
%% The handler's raw output is decoded before embedding in the response
%% so that the result is a proper JSON value rather than an escaped
%% string:
%%
%% ```
%% handler returns:  <<"[{\"url\":\"...\"}]">>   (binary)
%% response body:    {"results": [{"url": "..."}]}
%% '''
%%
%% @end
%%--------------------------------------------------------------------
init(Req0, #{server := ServerName} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 64_000, period => 5_000}),
    %% Step 1: decode and validate the request body.
    case (try {ok, json:decode(Body)} catch _:_ -> error end) of
        error ->
            Req2 = cowboy_req:reply(400, #{},
                <<"{\"error\":\"body must be JSON with a 'query' field\"}">>,
                Req1),
            {ok, Req2, State};
        {ok, #{<<"query">> := Query}} ->
            %% Step 2: call the agent server. Wrap separately so exit signals
            %% (timeout, noproc) are returned as 500, not confused with 400.
            CallResult = try gen_server:call(ServerName, {http_query, Query}, 30_000)
                         catch exit:ExitReason -> {error, ExitReason}
                         end,
            case CallResult of
                {ok, RawResult} ->
                    Decoded  = try json:decode(RawResult)
                               catch _:_ -> RawResult end,
                    RespBody = iolist_to_binary(
                        json:encode(#{<<"results">> => Decoded})),
                    Req2 = cowboy_req:reply(200,
                        #{<<"content-type">> => <<"application/json">>},
                        RespBody, Req1),
                    {ok, Req2, State};
                {error, Reason} ->
                    Msg  = iolist_to_binary(io_lib:format("~p", [Reason])),
                    Req2 = cowboy_req:reply(500,
                        #{<<"content-type">> => <<"application/json">>},
                        iolist_to_binary(
                            json:encode(#{<<"error">> => Msg})),
                        Req1),
                    {ok, Req2, State}
            end;
        {ok, _} ->
            %% Valid JSON but missing "query" key.
            Req2 = cowboy_req:reply(400, #{},
                <<"{\"error\":\"body must be JSON with a 'query' field\"}">>,
                Req1),
            {ok, Req2, State}
    end.
