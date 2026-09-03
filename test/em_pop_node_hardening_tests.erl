-module(em_pop_node_hardening_tests).
-include_lib("eunit/include/eunit.hrl").

netcheck_blocks_private_test() ->
    ?assert(em_pop_netcheck:is_blocked_ip({127,0,0,1})),
    ?assert(em_pop_netcheck:is_blocked_ip({10,0,0,5})),
    ?assert(em_pop_netcheck:is_blocked_ip({169,254,169,254})),
    ?assertNot(em_pop_netcheck:is_blocked_ip({93,184,216,34})).

netcheck_host_blocked_test() ->
    ?assertEqual(true,  em_pop_netcheck:host_blocked(<<"127.0.0.1">>)),
    ?assertEqual(false, em_pop_netcheck:host_blocked(<<"example.com">>)).

host_guard_rejects_private_from_nonroot_test() ->
    S0 = em_pop_node:test_state(#{reject_private_hosts => true, root_pubkeys => []}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"10.0.0.9">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"evil.example">>, pubkey => <<2:256>>}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assertNot(em_pop_node:has_peer(S1, <<1:128>>)).

host_guard_allows_private_from_root_test() ->
    Root = <<7:256>>,
    S0 = em_pop_node:test_state(#{reject_private_hosts => true, root_pubkeys => [Root]}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"localhost">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"root.example">>, pubkey => Root}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assert(em_pop_node:has_peer(S1, <<1:128>>)).

host_guard_allows_public_from_nonroot_test() ->
    S0 = em_pop_node:test_state(#{reject_private_hosts => true, root_pubkeys => []}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"93.184.216.34">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"peer.example">>, pubkey => <<2:256>>}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assert(em_pop_node:has_peer(S1, <<1:128>>)).

host_guard_off_keeps_private_test() ->
    S0 = em_pop_node:test_state(#{reject_private_hosts => false, root_pubkeys => []}),
    P  = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"10.0.0.9">>,
                                 query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"evil.example">>, pubkey => <<2:256>>}),
    S1 = em_pop_node:merge_peers_from([P], Src, S0),
    ?assert(em_pop_node:has_peer(S1, <<1:128>>)).

sybil_caps_nonroot_source_test() ->
    S0 = em_pop_node:test_state(#{max_peers_per_source => 2, root_pubkeys => []}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"h.example">>, pubkey => <<2:256>>}),
    Ps = [em_pop_node:test_peer(#{id => <<N:128>>, host => <<"93.184.216.34">>,
             query_port => 9200+N, vector => em_pop_node:test_vector(S0)}) || N <- [1,2,3,4]],
    S1 = em_pop_node:merge_peers_from(Ps, Src, S0),
    Kept = length([1 || N <- [1,2,3,4], em_pop_node:has_peer(S1, <<N:128>>)]),
    ?assertEqual(2, Kept).

sybil_root_source_unlimited_test() ->
    Root = <<7:256>>,
    S0 = em_pop_node:test_state(#{max_peers_per_source => 2, root_pubkeys => [Root]}),
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"r.example">>, pubkey => Root}),
    Ps = [em_pop_node:test_peer(#{id => <<N:128>>, host => <<"93.184.216.34">>,
             query_port => 9200+N, vector => em_pop_node:test_vector(S0)}) || N <- [1,2,3,4]],
    S1 = em_pop_node:merge_peers_from(Ps, Src, S0),
    ?assertEqual(4, length([1 || N <- [1,2,3,4], em_pop_node:has_peer(S1, <<N:128>>)])).

canonical_ban_stable_test() ->
    B = em_pop_crypto:canonical_ban(<<1:128>>, 1234567890),
    ?assert(is_binary(B)),
    ?assertEqual(B, em_pop_crypto:canonical_ban(<<1:128>>, 1234567890)).

ban_sign_verify_roundtrip_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Rec = em_pop_crypto:canonical_ban(<<1:128>>, 1234567890),
    Sig = em_pop_crypto:sign(Rec, Priv),
    ?assert(em_pop_crypto:verify(Rec, Sig, Pub)),
    ?assertNot(em_pop_crypto:verify(em_pop_crypto:canonical_ban(<<1:128>>, 9), Sig, Pub)).


shared_apply_authority_signed_ban_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    S1 = em_pop_node:test_add_peer(S0, <<1:128>>, <<"93.184.216.34">>),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Pub)},
    S2 = em_pop_node:apply_bans_from([Ban], S1),
    ?assert(em_pop_node:is_banned_st(S2, <<1:128>>)),
    ?assertNot(em_pop_node:has_peer(S2, <<1:128>>)).

shared_ignore_forged_ban_test() ->
    {_Pub, Priv} = em_pop_crypto:keypair(),
    {Auth, _} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Auth]}),
    S1 = em_pop_node:test_add_peer(S0, <<1:128>>, <<"93.184.216.34">>),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Auth)},
    S2 = em_pop_node:apply_bans_from([Ban], S1),
    ?assertNot(em_pop_node:is_banned_st(S2, <<1:128>>)),
    ?assert(em_pop_node:has_peer(S2, <<1:128>>)).

shared_banned_not_readmitted_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    Root = <<7:128>>,  %% not used as root here; source is nonroot
    Src = em_pop_node:test_peer(#{id => <<9:128>>, host => <<"h.example">>, pubkey => <<2:256>>}),
    P = em_pop_node:test_peer(#{id => <<1:128>>, host => <<"93.184.216.34">>,
                                query_port => 9201, vector => em_pop_node:test_vector(S0)}),
    S2 = em_pop_node:merge_peers_from([P], Src, S1),
    ?assertNot(em_pop_node:has_peer(S2, <<1:128>>)).

shared_relay_bans_in_payload_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    S0 = em_pop_node:test_state(#{ban_authority_pubkeys => [Pub]}),
    Ts = erlang:system_time(second),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_ban(<<1:128>>, Ts), Priv),
    Ban = #{<<"id">> => base64:encode(<<1:128>>), <<"ts">> => Ts,
            <<"sig">> => base64:encode(Sig), <<"signer">> => base64:encode(Pub)},
    S1 = em_pop_node:apply_bans_from([Ban], S0),
    Payload = em_pop_node:state_payload_for_test(S1),
    ?assertEqual(1, length(maps:get(<<"bans">>, Payload, []))).
