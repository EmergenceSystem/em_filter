%%%-------------------------------------------------------------------
%%% @doc
%%% Integration tests for em_pop network resilience:
%%%   - DETS persistence across restarts
%%%   - Trust-based peer eviction
%%%   - Auto-repair on isolation (from DETS and from seeds)
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_resilience_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([peers_restored_after_restart/1,
         trust_eviction_fires/1,
         trust_eviction_disabled_by_default/1,
         repair_from_seeds_on_isolation/1,
         repair_prefers_dets_over_seeds/1]).

all() -> [
    peers_restored_after_restart,
    trust_eviction_fires,
    trust_eviction_disabled_by_default,
    repair_from_seeds_on_isolation,
    repair_prefers_dets_over_seeds
].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    Config.

end_per_suite(_Config) -> ok.

init_per_testcase(TestCase, Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config),
                        atom_to_list(TestCase)),
    [{test_dir, Dir} | Config].

end_per_testcase(_TestCase, _Config) -> ok.

%%--------------------------------------------------------------------
%% peers_restored_after_restart
%%
%% A learns B, gossip_timer saves to DETS, A restarts with same
%% persist_dir → B is present without any network contact.
%%--------------------------------------------------------------------
peers_restored_after_restart(Config) ->
    Dir = proplists:get_value(test_dir, Config),
    Vec = em_filter_vec:from_capabilities([<<"rss">>]),

    %% B: a real node A can gossip with during add_peer
    {ok, B} = em_pop_node:start_link(#{port            => 19401,
                                        vector          => Vec,
                                        gossip_interval => 0}),

    %% A: persistence on, long intervals so timer never fires on its own
    {ok, A} = em_pop_node:start_link(#{port            => 19400,
                                        vector          => Vec,
                                        name            => <<"node_a_restart">>,
                                        gossip_interval => 999_999,
                                        stale_timeout   => 999_999,
                                        persist_dir     => Dir}),

    ok = em_pop_node:add_peer(A, "127.0.0.1", 19401),
    ?assertEqual(1, length(em_pop_node:get_peers(A))),

    %% Fire gossip_timer once: saves peers to DETS (step 1 of handler)
    A ! gossip_timer,
    timer:sleep(150),

    gen_server:stop(A),

    %% Restart A with same persist_dir → init loads DETS → B restored
    {ok, A2} = em_pop_node:start_link(#{port            => 19400,
                                         vector          => Vec,
                                         name            => <<"node_a_restart">>,
                                         gossip_interval => 999_999,
                                         stale_timeout   => 999_999,
                                         persist_dir     => Dir}),

    ?assertEqual(1, length(em_pop_node:get_peers(A2))),

    gen_server:stop(A2),
    gen_server:stop(B),
    ok.

%%--------------------------------------------------------------------
%% trust_eviction_fires
%%
%% A peer whose trust (0.10 = TRUST_INIT) is below evict_threshold
%% (0.15) is evicted on the next gossip_timer cleanup pass.
%%--------------------------------------------------------------------
trust_eviction_fires(_Config) ->
    Vec      = em_filter_vec:from_capabilities([<<"rss">>]),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),

    {ok, A} = em_pop_node:start_link(#{port            => 19410,
                                        vector          => Vec,
                                        gossip_interval => 999_999,
                                        stale_timeout   => 999_999,
                                        evict_threshold => 0.15}),

    %% Inject a peer via handle_gossip — trust = TRUST_INIT = 0.10
    em_pop_node:handle_gossip(A, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 19411,
        <<"query_port">> => null,
        <<"name">>       => <<"remote">>,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    ?assertEqual(1, length(em_pop_node:get_peers(A))),

    %% gossip_timer: save (no-op, no persist_dir) → cleanup_stale →
    %% trust 0.10 < threshold 0.15 → peer evicted
    A ! gossip_timer,
    timer:sleep(100),

    ?assertEqual([], em_pop_node:get_peers(A)),

    gen_server:stop(A),
    ok.

%%--------------------------------------------------------------------
%% trust_eviction_disabled_by_default
%%
%% With default evict_threshold=0.0, low-trust peers survive cleanup.
%%--------------------------------------------------------------------
trust_eviction_disabled_by_default(_Config) ->
    Vec      = em_filter_vec:from_capabilities([<<"rss">>]),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),

    {ok, A} = em_pop_node:start_link(#{port            => 19420,
                                        vector          => Vec,
                                        gossip_interval => 999_999,
                                        stale_timeout   => 999_999}),
                                        %% evict_threshold defaults to 0.0

    em_pop_node:handle_gossip(A, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 19421,
        <<"query_port">> => null,
        <<"name">>       => <<"remote">>,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    ?assertEqual(1, length(em_pop_node:get_peers(A))),

    A ! gossip_timer,
    timer:sleep(100),

    %% Peer survives: trust 0.10 >= evict_threshold 0.0
    ?assertEqual(1, length(em_pop_node:get_peers(A))),

    gen_server:stop(A),
    ok.

%%--------------------------------------------------------------------
%% repair_from_seeds_on_isolation
%%
%% When all peers are evicted (isolation) and DETS has content,
%% the node reconnects to the hosts saved in DETS.
%% Seeds are the fallback; here DETS and seeds point to the same host.
%%--------------------------------------------------------------------
repair_from_seeds_on_isolation(Config) ->
    Dir      = proplists:get_value(test_dir, Config),
    Vec      = em_filter_vec:from_capabilities([<<"rss">>]),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),

    {ok, B} = em_pop_node:start_link(#{port            => 19431,
                                        vector          => Vec,
                                        gossip_interval => 0}),

    {ok, A} = em_pop_node:start_link(#{port            => 19430,
                                        vector          => Vec,
                                        gossip_interval => 999_999,
                                        stale_timeout   => 999_999,
                                        evict_threshold => 0.15,
                                        persist_dir     => Dir,
                                        seeds           => [{"127.0.0.1", 19431}]}),

    %% Inject B into A's peer table (trust = TRUST_INIT = 0.10 < 0.15)
    em_pop_node:handle_gossip(A, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 19431,
        <<"query_port">> => null,
        <<"name">>       => <<"node_b">>,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    ?assertEqual(1, length(em_pop_node:get_peers(A))),

    %% gossip_timer:
    %%   1. save {B} to DETS
    %%   2. cleanup_stale: B evicted (trust 0.10 < 0.15) → isolation
    %%   3. repair_isolation sent to self
    %%   4. repair reads DETS → add_peer to B at 19431
    A ! gossip_timer,
    timer:sleep(500),

    ?assertNotEqual([], em_pop_node:get_peers(A)),

    gen_server:stop(A),
    gen_server:stop(B),
    ok.

%%--------------------------------------------------------------------
%% repair_prefers_dets_over_seeds
%%
%% When DETS is non-empty, repair uses DETS hosts and ignores seeds.
%% Seeds here point to a dead port (19499); B is only reachable via DETS.
%%--------------------------------------------------------------------
repair_prefers_dets_over_seeds(Config) ->
    Dir      = proplists:get_value(test_dir, Config),
    Vec      = em_filter_vec:from_capabilities([<<"rss">>]),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),

    {ok, B} = em_pop_node:start_link(#{port            => 19441,
                                        vector          => Vec,
                                        gossip_interval => 0}),

    {ok, A} = em_pop_node:start_link(#{port            => 19440,
                                        vector          => Vec,
                                        gossip_interval => 999_999,
                                        stale_timeout   => 999_999,
                                        evict_threshold => 0.15,
                                        persist_dir     => Dir,
                                        seeds           => [{"127.0.0.1", 19499}]}),
                                        %% 19499: nothing listening there

    em_pop_node:handle_gossip(A, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 19441,
        <<"query_port">> => null,
        <<"name">>       => <<"node_b_dets">>,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    ?assertEqual(1, length(em_pop_node:get_peers(A))),

    %% gossip_timer:
    %%   1. save {B at 19441} to DETS
    %%   2. B evicted → isolation
    %%   3. repair: DETS non-empty → add_peer to 19441 (B), skips dead seed 19499
    A ! gossip_timer,
    timer:sleep(500),

    Peers = em_pop_node:get_peers(A),
    ?assertNotEqual([], Peers),
    [PeerMap | _] = Peers,
    ?assertEqual(19441, maps:get(port, PeerMap)),

    gen_server:stop(A),
    gen_server:stop(B),
    ok.
