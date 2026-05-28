-module(em_pop_node_query_port_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([query_port_present_in_payload/1,
         query_port_null_when_absent/1,
         peer_map_exposes_query_port/1]).

all() ->
    [query_port_present_in_payload,
     query_port_null_when_absent,
     peer_map_exposes_query_port].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(kvex),
    Config.

end_per_suite(_Config) -> ok.

%% When query_port is set in Opts, it appears in the node's gossip payload.
query_port_present_in_payload(_Config) ->
    Vec  = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19201,
                                          query_port      => 19202,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    19202 = maps:get(<<"query_port">>, Payload),
    gen_server:stop(Pid),
    ok.

%% When query_port is absent from Opts, the payload carries null.
query_port_null_when_absent(_Config) ->
    Vec  = em_filter_vec:from_capabilities([<<"rss">>]),
    {ok, Pid} = em_pop_node:start_link(#{port            => 19203,
                                          vector          => Vec,
                                          gossip_interval => 0}),
    RemoteId = base64:encode(crypto:strong_rand_bytes(16)),
    {ok, Payload} = em_pop_node:handle_gossip(Pid, #{
        <<"id">>         => RemoteId,
        <<"host">>       => <<"127.0.0.1">>,
        <<"port">>       => 9999,
        <<"query_port">> => null,
        <<"vector">>     => base64:encode(Vec),
        <<"peers">>      => []
    }),
    null = maps:get(<<"query_port">>, Payload),
    gen_server:stop(Pid),
    ok.

%% query_port from a remote peer is captured in the peer map returned
%% by get_peers/1 after an add_peer call.
peer_map_exposes_query_port(_Config) ->
    Vec = em_filter_vec:from_capabilities([<<"web">>]),
    {ok, Remote} = em_pop_node:start_link(#{port            => 19204,
                                             query_port      => 19205,
                                             vector          => Vec,
                                             gossip_interval => 0}),
    {ok, Local}  = em_pop_node:start_link(#{port            => 19206,
                                             vector          => Vec,
                                             gossip_interval => 0}),
    ok = em_pop_node:add_peer(Local, "127.0.0.1", 19204),
    [PeerMap] = em_pop_node:get_peers(Local),
    19205 = maps:get(query_port, PeerMap),
    gen_server:stop(Remote),
    gen_server:stop(Local),
    ok.
