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
