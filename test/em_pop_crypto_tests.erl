-module(em_pop_crypto_tests).
-include_lib("eunit/include/eunit.hrl").

sign_verify_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    ?assertEqual(32, byte_size(Pub)),
    ?assertEqual(32, byte_size(Priv)),
    S = em_pop_crypto:sign(<<"m">>, Priv),
    ?assert(em_pop_crypto:verify(<<"m">>, S, Pub)),
    ?assertNot(em_pop_crypto:verify(<<"x">>, S, Pub)).

selfsig_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    Id = em_pop_crypto:id_of(Pub),
    I = #{id => Id, host => <<"h">>, port => 9100, query_port => 9101, name => <<"n">>},
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_identity(I), Priv),
    ?assert(em_pop_crypto:verify_selfsig(I#{pubkey => Pub, sig => Sig})).

canonical_response_deterministic_test() ->
    Items = [#{<<"url">> => <<"u1">>, <<"title">> => <<"t1">>, <<"resume">> => <<"r1">>},
             #{<<"properties">> => #{<<"url">> => <<"u2">>, <<"label">> => <<"t2">>}}],
    ?assertEqual(em_pop_crypto:canonical_response(Items),
                 em_pop_crypto:canonical_response(Items)),
    ?assert(is_binary(em_pop_crypto:canonical_response(Items))).

load_or_create_persists_test() ->
    Dir = "/tmp/emfilter_key_" ++ integer_to_list(erlang:unique_integer([positive])),
    {Pub1, _} = em_pop_crypto:load_or_create(Dir),
    {Pub2, _} = em_pop_crypto:load_or_create(Dir),
    ?assertEqual(Pub1, Pub2),
    ?assertEqual(em_pop_crypto:id_of(Pub1), em_pop_crypto:node_id()),
    {SignerId, _Sig} = em_pop_crypto:sign_response([#{<<"url">> => <<"u">>}]),
    ?assertEqual(base64:encode(em_pop_crypto:id_of(Pub1)), SignerId).
