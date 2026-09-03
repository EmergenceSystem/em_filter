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
