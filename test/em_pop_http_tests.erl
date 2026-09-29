-module(em_pop_http_tests).
-include_lib("eunit/include/eunit.hrl").

peers_within_cap_infinity_test() ->
    ?assert(em_pop_http:peers_within_cap(#{<<"peers">> => lists:seq(1, 9999)}, infinity)).

peers_within_cap_under_test() ->
    ?assert(em_pop_http:peers_within_cap(#{<<"peers">> => [a, b, c]}, 512)).

peers_within_cap_over_test() ->
    Peers = lists:duplicate(513, #{<<"id">> => <<"x">>}),
    ?assertNot(em_pop_http:peers_within_cap(#{<<"peers">> => Peers}, 512)).

peers_within_cap_no_peers_field_test() ->
    ?assert(em_pop_http:peers_within_cap(#{<<"id">> => <<"x">>}, 512)).

rate_key_prefixes_test() ->
    ?assertEqual(<<"gossip:203.0.113.9">>, em_pop_http:rate_key(<<"gossip:">>, <<"203.0.113.9">>)).

rate_key_empty_prefix_test() ->
    ?assertEqual(<<"203.0.113.9">>, em_pop_http:rate_key(<<>>, <<"203.0.113.9">>)).
