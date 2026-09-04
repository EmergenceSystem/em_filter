-module(em_pop_node_relay_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([relay_peer_added/1,
         relay_peer_advertised_with_relay_via/1,
         relay_via_and_caps_vector_roundtrip_over_gossip/1]).

all() ->
    [relay_peer_added,
     relay_peer_advertised_with_relay_via,
     relay_via_and_caps_vector_roundtrip_over_gossip].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    Config.

end_per_suite(_Config) -> ok.

%% add_relay_peer/2 inserts a peer with query_port=null, relay_via set to
%% the local node's own id, and a vector derived from the declared
%% capabilities (hub-authoritative recompute).
relay_peer_added(_Config) ->
    Vec = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19301,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    LocalId = em_pop_node:get_id(Pid),
    {Pub, _Priv} = em_pop_crypto:keypair(),
    RelayId = em_pop_crypto:id_of(Pub),
    ok = em_pop_node:add_relay_peer(Pid, #{
        id => RelayId, name => <<"r">>, pubkey => Pub,
        capabilities => [<<"search">>]}),
    %% add_relay_peer is a cast — give the gen_server a moment to apply it.
    timer:sleep(50),
    Peers = em_pop_node:get_peers(Pid),
    [P] = [X || X <- Peers, maps:get(id, X) =:= RelayId],
    null = maps:get(query_port, P, null),
    LocalIdB64 = base64:encode(LocalId),
    LocalIdB64 = maps:get(relay_via, P),
    ExpectedVec = em_filter_vec:from_capabilities([<<"search">>]),
    ExpectedVec = maps:get(vector, P),
    gen_server:stop(Pid),
    ok.

%% A relay peer is re-advertised (with relay_via carried) when this node's
%% state is serialised for gossip to a third party.
relay_peer_advertised_with_relay_via(_Config) ->
    Vec = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19302,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    LocalId = em_pop_node:get_id(Pid),
    {Pub, _Priv} = em_pop_crypto:keypair(),
    RelayId = em_pop_crypto:id_of(Pub),
    ok = em_pop_node:add_relay_peer(Pid, #{
        id => RelayId, name => <<"r2">>, pubkey => Pub,
        capabilities => [<<"web">>]}),
    timer:sleep(50),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    AdvPeers = maps:get(<<"peers">>, Payload),
    RelayIdB64 = base64:encode(RelayId),
    [AdvPeer] = [X || X <- AdvPeers, maps:get(<<"id">>, X) =:= RelayIdB64],
    null = maps:get(<<"query_port">>, AdvPeer),
    LocalIdB64 = base64:encode(LocalId),
    LocalIdB64 = maps:get(<<"relay_via">>, AdvPeer),
    gen_server:stop(Pid),
    ok.

%% A gossip payload that declares relay_via + null query_port + capabilities
%% round-trips through payload_to_peer/state_to_payload: query_port stays
%% undefined, relay_via decodes back to raw bytes, and the vector is
%% recomputed locally from the declared capabilities rather than trusted
%% from the wire.
relay_via_and_caps_vector_roundtrip_over_gossip(_Config) ->
    LocalVec = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19303,
                                          vector          => LocalVec,
                                          gossip_interval => 0}),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    BogusVec = crypto:strong_rand_bytes(byte_size(LocalVec)),
    {ok, _Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>           => RemoteId,
        <<"host">>         => <<"127.0.0.1">>,
        <<"port">>         => 9998,
        <<"query_port">>   => null,
        <<"relay_via">>    => base64:encode(<<"some-hub-id">>),
        <<"vector">>       => base64:encode(BogusVec),
        <<"capabilities">> => [<<"search">>],
        <<"peers">>        => []
    }),
    timer:sleep(50),
    Peers = em_pop_node:get_peers(Pid),
    RemoteIdRaw = base64:decode(RemoteId),
    [P] = [X || X <- Peers, maps:get(id, X) =:= RemoteIdRaw],
    null = maps:get(query_port, P, null),
    <<"some-hub-id">> = base64:decode(maps:get(relay_via, P)),
    ExpectedVec = em_filter_vec:from_capabilities([<<"search">>]),
    ExpectedVec = maps:get(vector, P),
    gen_server:stop(Pid),
    ok.
