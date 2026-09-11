%%%-------------------------------------------------------------------
%%% @doc ed25519 identity + signing for the em_pop mesh (OTP crypto).
%%% Peer id = SHA-256(pubkey)[0:16]. Canonical byte formats here MUST
%%% match Emquest's em_pop_crypto verbatim so cross-node verification works.
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_crypto).
-export([keypair/0, id_of/1, sign/2, verify/3,
         canonical_identity/1, canonical_response/1, verify_selfsig/1,
         load_or_create/1, pubkey/0, privkey/0, node_id/0, sign_response/1,
         canonical_ban/2, canonical_unban/2]).

-define(PT_KEY, {em_pop_crypto, keypair}).

-spec keypair() -> {binary(), binary()}.
keypair() -> crypto:generate_key(eddsa, ed25519).

-spec id_of(binary()) -> binary().
id_of(Pub) -> binary:part(crypto:hash(sha256, Pub), 0, 16).

-spec sign(binary(), binary()) -> binary().
sign(Msg, Priv) -> crypto:sign(eddsa, none, Msg, [Priv, ed25519]).

-spec verify(binary(), binary(), binary()) -> boolean().
verify(Msg, Sig, Pub) ->
    try crypto:verify(eddsa, none, Msg, Sig, [Pub, ed25519]) catch _:_ -> false end.

-spec canonical_identity(map()) -> binary().
%% STABLE identity only (id + name): hubs rewrite a leaf's host/port before
%% relaying, so signing those would break the self-signature. id=hash(pubkey)
%% already binds the key to the id. MUST stay byte-identical to Emquest's copy.
canonical_identity(M) ->
    Id   = to_bin(maps:get(id, M, <<>>)),
    Name = to_bin(maps:get(name, M, <<>>)),
    iolist_to_binary([Id, 0, Name]).

%% @doc Deterministic bytes over a response's item list. Covers the rendered
%% fields (url, title/label, resume/value/description) in list order. No JSON
%% dependency so both signer and verifier compute identical bytes.
-spec canonical_response(list()) -> binary().
canonical_response(Items) when is_list(Items) ->
    iolist_to_binary([item_line(I) || I <- Items]);
canonical_response(_) -> <<>>.

item_line(I) when is_map(I) ->
    P = case maps:get(<<"properties">>, I, undefined) of
            M when is_map(M) -> M; _ -> I
        end,
    U = pick(P, [<<"url">>]),
    T = pick(P, [<<"title">>, <<"label">>]),
    R = pick(P, [<<"resume">>, <<"value">>, <<"description">>]),
    [U, 0, T, 0, R, 10];
item_line(_) -> [0, 10].

pick(_M, []) -> <<>>;
pick(M, [K|Ks]) ->
    case maps:get(K, M, undefined) of
        V when is_binary(V) -> V;
        _ -> pick(M, Ks)
    end.

-spec verify_selfsig(map()) -> boolean().
verify_selfsig(#{pubkey := Pub, sig := Sig} = M) when is_binary(Pub), is_binary(Sig) ->
    (maps:get(id, M, undefined) =:= id_of(Pub))
        andalso verify(canonical_identity(M), Sig, Pub);
verify_selfsig(_) -> false.

%% @doc Load the node keypair from Dir/node_ed25519.key, creating+persisting it
%% if absent. Caches it in persistent_term for pubkey/0,privkey/0,sign_response/1.
-spec load_or_create(file:filename()) -> {binary(), binary()}.
load_or_create(Dir) ->
    File = filename:join(Dir, "node_ed25519.key"),
    KP = case file:read_file(File) of
             {ok, <<Pub:32/binary, Priv:32/binary>>} -> {Pub, Priv};
             _ ->
                 {Pub0, Priv0} = keypair(),
                 ok = filelib:ensure_dir(File),
                 ok = file:write_file(File, <<Pub0/binary, Priv0/binary>>),
                 {Pub0, Priv0}
         end,
    persistent_term:put(?PT_KEY, KP),
    KP.

-spec pubkey() -> binary() | undefined.
pubkey() -> case persistent_term:get(?PT_KEY, undefined) of {Pub,_} -> Pub; _ -> undefined end.

-spec privkey() -> binary() | undefined.
privkey() -> case persistent_term:get(?PT_KEY, undefined) of {_,Priv} -> Priv; _ -> undefined end.

-spec node_id() -> binary() | undefined.
node_id() -> case pubkey() of undefined -> undefined; Pub -> id_of(Pub) end.

%% @doc Sign a response item list. Returns {SignerIdBase64, SigBase64} or
%% undefined when no keypair is loaded (so callers stay backward-compatible).
-spec sign_response(list()) -> {binary(), binary()} | undefined.
sign_response(Items) ->
    case persistent_term:get(?PT_KEY, undefined) of
        {Pub, Priv} ->
            Sig = sign(canonical_response(Items), Priv),
            {base64:encode(id_of(Pub)), base64:encode(Sig)};
        _ -> undefined
    end.

qp(undefined) -> 0; qp(N) when is_integer(N) -> N; qp(_) -> 0.
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(_) -> <<>>.

%% @doc Deterministic bytes for a ban record. MUST stay byte-identical across
%% both repos (em_filter_src and Emquest) so a signature made by one verifies
%% in the other.
-spec canonical_ban(binary(), integer()) -> binary().
canonical_ban(BannedId, Ts) when is_binary(BannedId), is_integer(Ts) ->
    iolist_to_binary([BannedId, 0, integer_to_binary(Ts)]).

-spec canonical_unban(binary(), integer()) -> binary().
canonical_unban(BannedId, Ts) when is_binary(BannedId), is_integer(Ts) ->
    iolist_to_binary([BannedId, 1, integer_to_binary(Ts)]).
