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
-export([init/2, peers_within_cap/2, rate_key/2, authz_decision/5]).

%%--------------------------------------------------------------------
%% @doc Handle one POST /pop/gossip request.
%%
%% The Cowboy route must be configured with `#{node => NodePid}' as
%% the route options map, where `NodePid' is the `em_pop_node'
%% gen_server that owns this listener.
%%
%% Optional route option keys (absent = no limit, unchanged behaviour):
%%   `rate_limit => {Mod, Fun, Capacity, WindowSeconds}' — checked before
%%     authz; `Mod:Fun(ClientKey, Capacity, WindowSeconds)' must return a
%%     boolean, false yields HTTP 429.
%%   `rate_key_prefix => Bin' — prepended to the client key (default <<>>) so
%%     this route gets its own bucket in a shared limiter table.
%%   `max_body => Bytes' — larger request bodies yield HTTP 413.
%%   `max_peers => N' — payloads embedding more than N peers yield 413.
%%
%% On success returns `{ok, Req, State}' as required by Cowboy.
%% All error paths also return `{ok, Req, State}' — the HTTP status
%% code in the reply carries the error information.
%% @end
%%--------------------------------------------------------------------
init(Req0, State) ->
    case rate_ok(Req0, State) of
        false -> {ok, cowboy_req:reply(429, #{}, <<"rate_limited">>, Req0), State};
        true ->
            MaxBody = maps:get(max_body, State, infinity),
            case read_body_capped(Req0, MaxBody) of
                {too_large, Req1} ->
                    {ok, cowboy_req:reply(413, #{}, <<"payload_too_large">>, Req1), State};
                {ok, Body, Req1} ->
                    case authz(Req1, Body) of
                        ok -> handle(Req1, Body, State);
                unauthorized ->
                    {ok, cowboy_req:reply(401, #{}, <<"unauthorized">>, Req1), State}
            end
    end
    end.

rate_ok(Req, State) ->
    case maps:get(rate_limit, State, undefined) of
        undefined            -> true;
        {Mod, Fun, Cap, Win} ->
    Prefix = maps:get(rate_key_prefix, State, <<>>),
    Key = rate_key(Prefix, client_key(Req)),
    Mod:Fun(Key, Cap, Win)
    end.

%% @doc Compose the rate-limit bucket key: an optional route-configured
%% prefix isolates this endpoint's bucket from other users of the same
%% limiter table.
-spec rate_key(binary(), binary()) -> binary().
rate_key(Prefix, Ip) -> <<Prefix/binary, Ip/binary>>.

client_key(Req) ->
    case cowboy_req:header(<<"cf-connecting-ip">>, Req, undefined) of
        undefined ->
    {IP, _Port} = cowboy_req:peer(Req),
    iolist_to_binary(inet:ntoa(IP));
        Ip -> Ip
    end.

%% Authenticate a request: a valid ed25519 gossip signature (x-pop-id /
%% x-pop-ts / x-pop-sig) always passes; otherwise, unless
%% `require_signed_gossip' is true, fall back to the legacy shared bearer.
authz(Req, Body) ->
    Sig3 = {cowboy_req:header(<<"x-pop-id">>, Req, undefined),
    cowboy_req:header(<<"x-pop-ts">>, Req, undefined),
    cowboy_req:header(<<"x-pop-sig">>, Req, undefined)},
    Auth = cowboy_req:header(<<"authorization">>, Req, undefined),
    Bearer = application:get_env(em_filter, auth_token, undefined),
    Require = application:get_env(em_filter, require_signed_gossip, false) =:= true,
    authz_decision(Sig3, Body, Bearer, Auth, Require).

%% @doc Pure authorization decision.
%% `Sig3' is the {x-pop-id, x-pop-ts, x-pop-sig} header triple (each a
%% binary/string or `undefined'); `Body' the raw request body; `Bearer' the
%% configured shared token (or `undefined'); `AuthHeader' the incoming
%% `authorization' header; `Require' whether signed gossip is mandatory.
-spec authz_decision({term(), term(), term()}, binary(), binary() | undefined,
             binary() | undefined, boolean()) -> ok | unauthorized.
authz_decision(Sig3, Body, Bearer, AuthHeader, Require) ->
    case valid_signature(Sig3, Body) of
        true -> ok;
        false when Require =:= true -> unauthorized;
        false -> bearer_decision(Bearer, AuthHeader)
    end.

bearer_decision(undefined, _AuthHeader) -> ok;
bearer_decision(Tok, AuthHeader) when is_binary(Tok) ->
    case AuthHeader =:= <<"Bearer ", Tok/binary>> of
        true -> ok;
        false -> unauthorized
    end;
bearer_decision(Tok, AuthHeader) when is_list(Tok) ->
    bearer_decision(list_to_binary(Tok), AuthHeader);
bearer_decision(_, _) -> unauthorized.

%% Self-contained: the sender pubkey comes from the body's own pubkey+sig
%% selfsig, which must bind id_of(Pub); x-pop-id must equal that id.
valid_signature({IdH, TsH, SigH}, Body)
  when IdH =/= undefined, TsH =/= undefined, SigH =/= undefined ->
    try
        #{<<"pubkey">> := PubB64, <<"sig">> := SelfSigB64} = Payload = json:decode(Body),
        Pub = base64:decode(PubB64),
        Id = em_pop_crypto:id_of(Pub),
        Name = maps:get(<<"name">>, Payload, <<>>),
        true = is_binary(Name),
        true = em_pop_crypto:verify_selfsig(#{id => Id, name => Name, pubkey => Pub,
                                      sig => base64:decode(SelfSigB64)}),
        true = base64:decode(to_bin(IdH)) =:= Id,
        Ts = binary_to_integer(to_bin(TsH)),
        true = fresh(Ts),
        em_pop_crypto:verify(
    em_pop_crypto:canonical_gossip_auth(Id, Ts, crypto:hash(sha256, Body)),
    base64:decode(to_bin(SigH)), Pub)
    catch
        _:_ -> false
    end;
valid_signature(_, _) -> false.

fresh(Ts) ->
    Now = erlang:system_time(millisecond),
    Max = application:get_env(em_filter, gossip_auth_max_age_ms, 120000),
    Skew = 30000,
    Ts =< Now + Skew andalso Ts >= Now - Max.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

handle(Req1, Body, #{node := NodePid} = State) ->
    MaxPeers = maps:get(max_peers, State, infinity),
    try
        InPayload = json:decode(Body),
        case peers_within_cap(InPayload, MaxPeers) of
            false ->
                {ok, cowboy_req:reply(413, #{}, <<"too_many_peers">>, Req1), State};
            true ->
                case em_pop_node:handle_gossip(NodePid, InPayload) of
                    {ok, OutPayload} ->
                        RespBody = iolist_to_binary(json:encode(OutPayload)),
                        Req2 = cowboy_req:reply(200,
                            #{<<"content-type">> => <<"application/json">>},
                            RespBody, Req1),
                        {ok, Req2, State};
                    {error, Reason} ->
                        Msg  = iolist_to_binary(io_lib:format("~p", [Reason])),
                        Req2 = cowboy_req:reply(500,
                            #{<<"content-type">> => <<"application/json">>},
                            iolist_to_binary(json:encode(#{<<"error">> => Msg})),
                            Req1),
                        {ok, Req2, State}
                end
        end
    catch
        _:_ ->
            ErrReq = cowboy_req:reply(400, #{}, <<"bad request">>, Req1),
            {ok, ErrReq, State}
    end.

read_body_capped(Req0, infinity) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    {ok, Body, Req1};
read_body_capped(Req0, Max) when is_integer(Max) ->
    case cowboy_req:read_body(Req0, #{length => Max + 1}) of
        {ok, Body, Req1} when byte_size(Body) =< Max -> {ok, Body, Req1};
        {ok, _Body, Req1}  -> {too_large, Req1};
        {more, _Body, Req1} -> {too_large, Req1}
    end.

-spec peers_within_cap(map(), non_neg_integer() | infinity) -> boolean().
peers_within_cap(_Payload, infinity) -> true;
peers_within_cap(#{<<"peers">> := L}, Max) when is_list(L) -> length(L) =< Max;
peers_within_cap(_Payload, _Max) -> true.
