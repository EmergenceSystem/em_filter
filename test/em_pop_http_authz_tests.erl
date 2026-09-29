-module(em_pop_http_authz_tests).
-include_lib("eunit/include/eunit.hrl").

mkbody(Pub, Priv) ->
    Id = em_pop_crypto:id_of(Pub),
    Name = <<"n">>,
    SelfSig = em_pop_crypto:sign(em_pop_crypto:canonical_identity(#{id => Id, name => Name}), Priv),
    Body = iolist_to_binary(json:encode(#{<<"id">> => base64:encode(Id), <<"name">> => Name,
        <<"pubkey">> => base64:encode(Pub), <<"sig">> => base64:encode(SelfSig)})),
    {Id, Body}.

mkhdrs(Id, Body, Priv) ->
    Ts = erlang:system_time(millisecond),
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_gossip_auth(Id, Ts, crypto:hash(sha256, Body)), Priv),
    {binary_to_list(base64:encode(Id)), integer_to_list(Ts), binary_to_list(base64:encode(Sig))}.

valid_sig_accepted_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    {IdH, TsH, SigH} = mkhdrs(Id, Body, Priv),
    ?assertEqual(ok, em_pop_http:authz_decision({IdH, TsH, SigH}, Body, undefined, undefined, true)).

valid_sig_binary_headers_accepted_test() ->
    %% cowboy_req:header/3 yields binaries, not strings.
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    {IdH, TsH, SigH} = mkhdrs(Id, Body, Priv),
    ?assertEqual(ok, em_pop_http:authz_decision(
        {list_to_binary(IdH), list_to_binary(TsH), list_to_binary(SigH)},
        Body, undefined, undefined, true)).

valid_sig_beats_wrong_bearer_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    {IdH, TsH, SigH} = mkhdrs(Id, Body, Priv),
    ?assertEqual(ok, em_pop_http:authz_decision({IdH, TsH, SigH}, Body, <<"tok">>, <<"Bearer nope">>, false)).

bad_sig_rejected_when_enforced_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    {IdH, TsH, _} = mkhdrs(Id, Body, Priv),
    ?assertEqual(unauthorized, em_pop_http:authz_decision({IdH, TsH, "AAAA"}, Body, undefined, undefined, true)).

tampered_body_rejected_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    {IdH, TsH, SigH} = mkhdrs(Id, Body, Priv),
    ?assertEqual(unauthorized, em_pop_http:authz_decision({IdH, TsH, SigH}, <<Body/binary, " ">>,
                                                          undefined, undefined, true)).

id_mismatch_rejected_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    {_, TsH, SigH} = mkhdrs(Id, Body, Priv),
    Wrong = binary_to_list(base64:encode(crypto:strong_rand_bytes(16))),
    ?assertEqual(unauthorized, em_pop_http:authz_decision({Wrong, TsH, SigH}, Body, undefined, undefined, true)).

garbage_body_rejected_test() ->
    {_Pub, Priv} = em_pop_crypto:keypair(),
    Id = crypto:strong_rand_bytes(16),
    Body = <<"not json">>,
    {IdH, TsH, SigH} = mkhdrs(Id, Body, Priv),
    ?assertEqual(unauthorized, em_pop_http:authz_decision({IdH, TsH, SigH}, Body, undefined, undefined, true)).

stale_ts_rejected_test() ->
    {Pub, Priv} = em_pop_crypto:keypair(),
    {Id, Body} = mkbody(Pub, Priv),
    OldTs = erlang:system_time(millisecond) - 3600000,
    Sig = em_pop_crypto:sign(em_pop_crypto:canonical_gossip_auth(Id, OldTs, crypto:hash(sha256, Body)), Priv),
    ?assertEqual(unauthorized, em_pop_http:authz_decision(
        {binary_to_list(base64:encode(Id)), integer_to_list(OldTs), binary_to_list(base64:encode(Sig))},
        Body, undefined, undefined, true)).

bearer_ok_when_optional_test() ->
    ?assertEqual(ok, em_pop_http:authz_decision({undefined,undefined,undefined}, <<"{}">>, <<"tok">>, <<"Bearer tok">>, false)).

bearer_wrong_when_optional_rejected_test() ->
    ?assertEqual(unauthorized, em_pop_http:authz_decision({undefined,undefined,undefined}, <<"{}">>, <<"tok">>, <<"Bearer bad">>, false)).

bearer_ignored_when_enforced_test() ->
    ?assertEqual(unauthorized, em_pop_http:authz_decision({undefined,undefined,undefined}, <<"{}">>, <<"tok">>, <<"Bearer tok">>, true)).

no_auth_enforced_rejected_test() ->
    ?assertEqual(unauthorized, em_pop_http:authz_decision({undefined,undefined,undefined}, <<"{}">>, undefined, undefined, true)).

no_auth_optional_open_when_no_token_test() ->
    %% legacy behavior: auth_token unset + not enforced => open
    ?assertEqual(ok, em_pop_http:authz_decision({undefined,undefined,undefined}, <<"{}">>, undefined, undefined, false)).
