%%%-------------------------------------------------------------------
%%% @doc
%%% em_pop_http — Cowboy HTTP handler for the Population Protocol
%%% gossip endpoint.
%%%
%%% Route: POST /pop/gossip
%%%
%%% This handler is the network entry point for peer-to-peer gossip
%%% exchanges.  When a remote em_pop node wants to exchange state with
%%% this node, it sends an HTTP POST here carrying its own serialised
%%% state as a JSON body.
%%%
%%% === Request flow ===
%%%
%%%   1. Read the full request body.
%%%   2. JSON-decode it into an Erlang map (the remote node's payload).
%%%   3. Forward the payload to `em_pop_node:handle_gossip/2', which
%%%      updates the local peer table and returns our own state as a
%%%      response payload.
%%%   4. JSON-encode the response and reply with HTTP 200.
%%%
%%% === Error handling ===
%%%
%%%   • Malformed JSON or a missing body field → 400 Bad Request.
%%%   • Internal error from `handle_gossip/2'  → 500 with JSON error body.
%%%
%%% The handler is stateless beyond the `node' pid passed in the
%%% Cowboy route options at startup.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_http).
-behaviour(cowboy_handler).
-export([init/2]).

%%--------------------------------------------------------------------
%% @doc Handle one POST /pop/gossip request.
%%
%% The Cowboy route must be configured with `#{node => NodePid}' as
%% the route options map, where `NodePid' is the `em_pop_node'
%% gen_server that owns this listener.
%%
%% On success returns `{ok, Req, State}' as required by Cowboy.
%% All error paths also return `{ok, Req, State}' — the HTTP status
%% code in the reply carries the error information.
%% @end
%%--------------------------------------------------------------------
init(Req0, #{node := NodePid} = State) ->
    %% Read the full request body before any processing.
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    try
        %% Decode the remote node's gossip payload.
        InPayload = json:decode(Body),

        case em_pop_node:handle_gossip(NodePid, InPayload) of
            {ok, OutPayload} ->
                %% Gossip accepted — reply with our own current state
                %% so the caller can merge it on their side too.
                RespBody = iolist_to_binary(json:encode(OutPayload)),
                Req2 = cowboy_req:reply(200,
                    #{<<"content-type">> => <<"application/json">>},
                    RespBody, Req1),
                {ok, Req2, State};

            {error, Reason} ->
                %% em_pop_node rejected the payload (unknown peer format,
                %% etc.).  Return a 500 with a JSON error description.
                Msg  = iolist_to_binary(io_lib:format("~p", [Reason])),
                Req2 = cowboy_req:reply(500,
                    #{<<"content-type">> => <<"application/json">>},
                    iolist_to_binary(json:encode(#{<<"error">> => Msg})),
                    Req1),
                {ok, Req2, State}
        end
    catch
        %% Any decode failure (invalid JSON, unexpected structure) is a
        %% client error.  Use a fresh variable name (ErrReq) to avoid
        %% Erlang's "unsafe variable in catch" compile error.
        _:_ ->
            ErrReq = cowboy_req:reply(400, #{}, <<"bad request">>, Req1),
            {ok, ErrReq, State}
    end.
