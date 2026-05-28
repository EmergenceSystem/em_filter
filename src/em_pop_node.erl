%%%-------------------------------------------------------------------
%%% @doc
%%% em_pop_node — Population Protocol node (gen_server)
%%%
%%% Implements the Angluin et al. (2004) Population Protocol model as
%%% a concrete Erlang process with HTTP-based pairwise interactions.
%%%
%%% === What this process holds ===
%%%
%%%   • A unique 16-byte random binary ID (generated at startup).
%%%   • A semantic capability vector — an f32 flat binary produced by
%%%     `em_filter_vec:from_capabilities/1'.
%%%   • A peer map: `#{PeerId => #peer{}}' for every known node.
%%%   • A kvex SIMD index for O(log N) cosine-similarity search.
%%%
%%% === Population Protocol transition (gossip_tick/1) ===
%%%
%%%   1. Pick a random peer from the known peer map.
%%%   2. Serialise our own state to a JSON-encodable map (payload).
%%%   3. HTTP POST /pop/gossip to the peer — this is the PP "interaction".
%%%   4. Receive the peer's payload in the HTTP response body.
%%%   5. Merge the peer's peer list into our own (transitive discovery).
%%%
%%% After O(N log N) interactions, every node in a connected graph
%%% converges to knowing every other node — without any coordinator.
%%%
%%% === Trust model ===
%%%
%%%   Trust is a float in [0.0, 1.0] per peer.
%%%   • First contact  → TRUST_INIT   (0.10)
%%%   • Successful exchange → +TRUST_INCREMENT (0.10), capped at 1.0
%%%   • Failed exchange     → -TRUST_DECAY    (0.05), floored at 0.0
%%%
%%% === Background gossip ===
%%%
%%%   A timer fires every `gossip_interval' ms.  The HTTP call is
%%%   executed in a spawned process so the gen_server never blocks.
%%%   Results arrive as `{gossip_result, PeerId, Result}' messages.
%%%
%%% === Stale peer eviction ===
%%%
%%%   Every background tick evicts peers whose `last_seen' timestamp
%%%   is older than `stale_timeout' ms.  The kvex index is rebuilt
%%%   from scratch after any eviction or vector change.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_node).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([start_link/1]).
-export([get_id/1, get_vector/1, add_peer/3, get_peers/1,
         peers_for/3, get_trust/2, gossip_tick/1, handle_gossip/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%%====================================================================
%% Constants
%%====================================================================

%% Milliseconds before a peer that has not been heard from is evicted.
-define(DEFAULT_STALE_TIMEOUT,    30_000).

%% Milliseconds between background gossip ticks.  Set to 0 to disable
%% the background loop entirely (manual / test mode).
-define(DEFAULT_GOSSIP_INTERVAL,   5_000).

%% Maximum number of peers this node will maintain.  Gossip-discovered
%% peers beyond this limit are silently dropped.
-define(DEFAULT_MAX_PEERS,           200).

%% Timeout for a single HTTP gossip POST (ms).
-define(GOSSIP_HTTP_TIMEOUT,       5_000).

%% Initial trust score assigned to a peer on first contact.
-define(TRUST_INIT,                 0.10).

%% Trust gain per successful gossip exchange.
-define(TRUST_INCREMENT,            0.10).

%% Trust loss per failed gossip exchange.
-define(TRUST_DECAY,                0.05).

%% Hard bounds on the trust score.
-define(TRUST_MAX,                  1.00).
-define(TRUST_MIN,                  0.00).

%%====================================================================
%% Records
%%====================================================================

%% Internal representation of one remote peer.
-record(peer, {
    id                     :: binary(),           %% 16-byte unique identifier
    host                   :: binary(),           %% hostname or IP (binary string)
    port                   :: inet:port_number(), %% TCP port of the peer's gossip listener
    query_port = undefined :: pos_integer() | undefined,  %% direct HTTP query port (null if not exposed)
    name = <<>>            :: binary(),           %% human-readable agent name (OTP app name)
    vector                 :: binary(),           %% capability vector (f32 flat binary)
    trust = 0.0            :: float(),            %% trust score in [0.0, 1.0]
    last_seen              :: integer()           %% erlang:monotonic_time(millisecond)
}).

%% gen_server state for the local node.
-record(state, {
    id                          :: binary(),                   %% this node's unique ID
    host = <<"localhost">>      :: binary(),                   %% advertised hostname
    port                        :: inet:port_number(),         %% gossip HTTP listener port
    query_port = undefined      :: pos_integer() | undefined,  %% direct HTTP query port (null if not exposed)
    name = <<>>                 :: binary(),                   %% human-readable agent name (OTP app name)
    vector                      :: binary(),                   %% this node's capability vector
    peers = #{}                 :: #{binary() => #peer{}},     %% known peers by ID
    kvex_ix                     :: term(),                     %% kvex cosine-search index
    stale_timeout               :: pos_integer(),              %% peer eviction threshold (ms)
    gossip_interval             :: non_neg_integer(),          %% background tick interval (ms)
    max_peers                   :: pos_integer()               %% peer list capacity
}).

%%====================================================================
%% Public API
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Start a Population Protocol node linked to the calling process.
%%
%% Opts is a map with the following keys:
%%
%%%   port            => pos_integer()  — required; TCP port for gossip HTTP
%%%   vector          => binary()       — required; f32 capability vector
%%%   stale_timeout   => pos_integer()  — optional; default 30 000 ms
%%%   gossip_interval => non_neg_integer() — optional; default 5 000 ms
%%%   max_peers       => pos_integer()  — optional; default 200
%% @end
%%--------------------------------------------------------------------
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc Return this node's unique binary identifier (16 bytes).
-spec get_id(pid()) -> binary().
get_id(Pid) -> gen_server:call(Pid, get_id).

%% @doc Return the capability vector this node was started with.
-spec get_vector(pid()) -> binary().
get_vector(Pid) -> gen_server:call(Pid, get_vector).

%%--------------------------------------------------------------------
%% @doc Contact a remote em_pop node and register it as a known peer.
%%
%% Performs a full bidirectional gossip exchange: sends our state,
%% receives theirs, and merges their peer list into ours.
%%
%% Timeout is 15 s because the HTTP call may take up to
%% GOSSIP_HTTP_TIMEOUT (5 s) plus gen_server scheduling overhead.
%% @end
%%--------------------------------------------------------------------
-spec add_peer(pid(), string(), inet:port_number()) -> ok | {error, term()}.
add_peer(Pid, Host, Port) ->
    gen_server:call(Pid, {add_peer, Host, Port}, 15_000).

%% @doc Return all currently known peers as a list of plain maps.
-spec get_peers(pid()) -> [map()].
get_peers(Pid) -> gen_server:call(Pid, get_peers).

%%--------------------------------------------------------------------
%% @doc Return the top-K peers ordered by cosine similarity to QueryVec.
%%
%% QueryVec must be an f32 little-endian binary of the same dimension
%% as the vectors stored in this node's kvex index.
%%
%% Returns a list of `{PeerMap, Score}' tuples sorted by descending
%% similarity score.  Returns `[]' when the peer list is empty.
%% @end
%%--------------------------------------------------------------------
-spec peers_for(pid(), binary(), pos_integer()) -> [{map(), float()}].
peers_for(Pid, Vec, K) -> gen_server:call(Pid, {peers_for, Vec, K}).

%% @doc Return the trust score for PeerId (0.0 if unknown, 1.0 if fully trusted).
-spec get_trust(pid(), binary()) -> float().
get_trust(Pid, PeerId) -> gen_server:call(Pid, {get_trust, PeerId}).

%%--------------------------------------------------------------------
%% @doc Trigger one synchronous gossip tick.
%%
%% Picks a random peer, performs the HTTP exchange, and merges the
%% result — all in the calling process's context.  The gen_server is
%% blocked for the duration of the HTTP call (up to GOSSIP_HTTP_TIMEOUT).
%%
%% Intended for tests and manual invocation.  The background timer
%% uses an async pattern instead to keep the gen_server responsive.
%% @end
%%--------------------------------------------------------------------
-spec gossip_tick(pid()) -> ok.
gossip_tick(Pid) -> gen_server:call(Pid, gossip_tick, 15_000).

%%--------------------------------------------------------------------
%% @doc Handle an incoming gossip payload from a remote node.
%%
%% Called by `em_pop_http' when a POST /pop/gossip arrives.
%% Merges the remote node into our peer table and returns our own
%% current state as the reply payload.
%% @end
%%--------------------------------------------------------------------
-spec handle_gossip(pid(), map()) -> {ok, map()} | {error, term()}.
handle_gossip(Pid, Payload) -> gen_server:call(Pid, {handle_gossip, Payload}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Initialise the node.
%%
%% Steps:
%%   1. Extract options from the Opts map.
%%   2. Generate a unique 16-byte ID via crypto:strong_rand_bytes/1.
%%   3. Ensure `inets' (for httpc) is started.
%%   4. Start the Cowboy HTTP listener on the configured port.
%%   5. Create an empty kvex index sized to the vector dimension.
%%   6. Schedule the first background gossip tick (unless disabled).
%% @end
%%--------------------------------------------------------------------
init(Opts) ->
    Port      = maps:get(port,            Opts),
    Vec       = maps:get(vector,          Opts),
    StaleT    = maps:get(stale_timeout,   Opts, ?DEFAULT_STALE_TIMEOUT),
    GossipI   = maps:get(gossip_interval, Opts, ?DEFAULT_GOSSIP_INTERVAL),
    MaxP      = maps:get(max_peers,       Opts, ?DEFAULT_MAX_PEERS),
    QueryPort = maps:get(query_port,      Opts, undefined),
    Name      = maps:get(name,            Opts, <<>>),
    Id      = generate_id(),

    %% Vector dimension is byte_size / 4 because each float is 32-bit.
    Dim = byte_size(Vec) div 4,

    %% httpc lives inside the inets application — start it if not yet up.
    application:ensure_all_started(inets),

    %% Start the Cowboy listener that will accept incoming gossip POSTs.
    ok = start_listener(Port, self()),

    %% Empty kvex index — vectors are added one by one as peers are discovered.
    {ok, Ix} = kvex:new(Dim),

    %% Schedule the background gossip loop (0 = disabled, e.g. in tests).
    case GossipI of
        0 -> ok;
        I -> erlang:send_after(I, self(), gossip_timer)
    end,

    ?LOG_INFO("em_pop node started id=~s port=~w", [short_id(Id), Port]),

    {ok, #state{
        id              = Id,
        port            = Port,
        query_port      = QueryPort,
        name            = Name,
        vector          = Vec,
        kvex_ix         = Ix,
        stale_timeout   = StaleT,
        gossip_interval = GossipI,
        max_peers       = MaxP
    }}.

%% --- Simple state accessors ---

handle_call(get_id, _From, State) ->
    {reply, State#state.id, State};

handle_call(get_vector, _From, State) ->
    {reply, State#state.vector, State};

handle_call(get_peers, _From, State) ->
    %% Convert internal #peer{} records to plain maps for the caller.
    {reply, peers_to_maps(maps:values(State#state.peers)), State};

%%--------------------------------------------------------------------
%% @private
%% @doc Perform a full bidirectional gossip exchange with a new peer.
%%
%% On success: register the remote node as a peer and merge its own
%% peer list into ours (transitive discovery).
%% On failure: reply with the error — the caller decides what to do.
%% @end
%%--------------------------------------------------------------------
handle_call({add_peer, Host, Port}, _From, State) ->
    Url     = gossip_url(Host, Port),
    Payload = state_to_payload(State),
    case http_post(Url, Payload) of
        {ok, RemotePayload} ->
            Remote      = payload_to_peer(RemotePayload),
            RemotePeers = payload_to_peers(RemotePayload),
            State1 = upsert_peer(Remote, State),
            State2 = merge_peers(RemotePeers, State1),
            ?LOG_DEBUG("em_pop add_peer ok ~s:~w", [Host, Port]),
            {reply, ok, State2};
        {error, Reason} ->
            ?LOG_WARNING("em_pop add_peer failed ~s:~w reason=~p",
                         [Host, Port, Reason]),
            {reply, {error, Reason}, State}
    end;

%%--------------------------------------------------------------------
%% @private
%% @doc Return the K nearest peers by cosine similarity to QueryVec.
%%
%% Clamps K to the actual peer count to avoid kvex index errors.
%% @end
%%--------------------------------------------------------------------
handle_call({peers_for, QueryVec, K}, _From,
            #state{peers = Peers, kvex_ix = Ix} = State) ->
    Result = case map_size(Peers) of
        0 ->
            %% No peers yet — nothing to search.
            [];
        N ->
            ActualK = min(K, N),
            {ok, Hits} = kvex:search(Ix, QueryVec, ActualK),
            %% Hydrate the search hits with the full peer map.
            [{peer_to_map(maps:get(Id, Peers)), Score} || {Id, Score} <- Hits]
    end,
    {reply, Result, State};

handle_call({get_trust, PeerId}, _From, #state{peers = Peers} = State) ->
    Trust = case maps:find(PeerId, Peers) of
        {ok, #peer{trust = T}} -> T;
        error                  -> 0.0   %% unknown peer → lowest possible trust
    end,
    {reply, Trust, State};

%% Synchronous gossip tick — no-op when there are no peers yet.
handle_call(gossip_tick, _From, #state{peers = Peers} = State)
        when map_size(Peers) =:= 0 ->
    {reply, ok, State};

%%--------------------------------------------------------------------
%% @private
%% @doc Synchronous gossip tick (manual / test mode).
%%
%% Picks a random peer, posts our state, merges the response.
%% The gen_server is blocked for the duration of the HTTP call.
%% Use the background timer path for production — it never blocks.
%% @end
%%--------------------------------------------------------------------
handle_call(gossip_tick, _From, State) ->
    {PeerId, Url} = pick_gossip_target(State),
    Payload = state_to_payload(State),
    NewState = case http_post(Url, Payload) of
        {ok, RemotePayload} ->
            Remote      = payload_to_peer(RemotePayload),
            RemotePeers = payload_to_peers(RemotePayload),
            State1 = upsert_peer(Remote, State),
            merge_peers(RemotePeers, State1);
        {error, Reason} ->
            ?LOG_DEBUG("em_pop gossip_tick failed peer=~s reason=~p",
                       [short_id(PeerId), Reason]),
            %% Failed exchange — penalise the peer's trust score.
            decay_trust(PeerId, State)
    end,
    {reply, ok, NewState};

%%--------------------------------------------------------------------
%% @private
%% @doc Handle an incoming gossip request from a remote node.
%%
%% Called via `em_pop_http' when a POST /pop/gossip arrives.
%% We merge the remote's state into ours, then reply with our own
%% updated state so the remote can do the same.  This makes every
%% gossip exchange bidirectional.
%% @end
%%--------------------------------------------------------------------
handle_call({handle_gossip, InPayload}, _From, State) ->
    Remote      = payload_to_peer(InPayload),
    RemotePeers = payload_to_peers(InPayload),
    State1 = upsert_peer(Remote, State),
    State2 = merge_peers(RemotePeers, State1),
    {reply, {ok, state_to_payload(State2)}, State2};

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Background gossip timer tick.
%%
%% Fires every `gossip_interval' ms.  The HTTP call is dispatched to a
%% short-lived spawned process so the gen_server is never blocked.
%% The spawned process sends `{gossip_result, PeerId, Result}' back.
%%
%% Also runs the stale peer eviction pass and re-arms the timer.
%% @end
%%--------------------------------------------------------------------
handle_info(gossip_timer, #state{gossip_interval = I,
                                  stale_timeout   = St,
                                  peers           = Peers} = State) ->
    case map_size(Peers) of
        0 ->
            %% No peers yet — nothing to gossip with.
            ok;
        _ ->
            {PeerId, Url} = pick_gossip_target(State),
            Payload = state_to_payload(State),
            Self = self(),
            %% Spawn the HTTP call so the gen_server stays responsive.
            spawn(fun() ->
                Result = http_post(Url, Payload),
                Self ! {gossip_result, PeerId, Result}
            end)
    end,
    %% Evict stale peers before rescheduling.
    State1 = cleanup_stale(St, State),
    erlang:send_after(I, self(), gossip_timer),
    {noreply, State1};

%% Async gossip result — successful exchange: merge the remote's state.
handle_info({gossip_result, _PeerId, {ok, RemotePayload}}, State) ->
    Remote      = payload_to_peer(RemotePayload),
    RemotePeers = payload_to_peers(RemotePayload),
    State1 = upsert_peer(Remote, State),
    State2 = merge_peers(RemotePeers, State1),
    {noreply, State2};

%% Async gossip result — failed exchange: penalise trust, keep going.
handle_info({gossip_result, PeerId, {error, Reason}}, State) ->
    ?LOG_DEBUG("em_pop bg gossip failed peer=~s reason=~p",
               [short_id(PeerId), Reason]),
    {noreply, decay_trust(PeerId, State)};

handle_info(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Stop the Cowboy listener when the node goes down.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{port = Port, id = Id}) ->
    ?LOG_INFO("em_pop node stopping id=~s port=~w", [short_id(Id), Port]),
    cowboy:stop_listener(listener_ref(Port)),
    ok.

%%====================================================================
%% Internal — gossip logic
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Pick one random peer from the peer map.
%%
%% Returns `{PeerId, GossipUrl}' where the URL is the full HTTP address
%% of that peer's /pop/gossip endpoint.
%% @end
%%--------------------------------------------------------------------
-spec pick_gossip_target(#state{}) -> {binary(), string()}.
pick_gossip_target(#state{peers = Peers}) ->
    Ids    = maps:keys(Peers),
    PeerId = lists:nth(rand:uniform(length(Ids)), Ids),
    #peer{host = H, port = P} = maps:get(PeerId, Peers),
    {PeerId, gossip_url(binary_to_list(H), P)}.

%%--------------------------------------------------------------------
%% @private
%% @doc Add a new peer or refresh an existing one.
%%
%% On first contact the peer's vector is inserted into the kvex index.
%% On subsequent contacts the trust score is incremented.
%% If the peer's vector changed between contacts (e.g. the remote node
%% was restarted with different capabilities) the kvex index is rebuilt
%% from scratch to keep it consistent.
%% @end
%%--------------------------------------------------------------------
-spec upsert_peer(#peer{}, #state{}) -> #state{}.
upsert_peer(#peer{id = Id} = New,
            #state{peers = Peers, kvex_ix = Ix} = State) ->
    {Trust, NeedsReindex} = case maps:find(Id, Peers) of
        {ok, #peer{trust = T, vector = OldVec}} ->
            %% Already known — check for vector change.
            VecChanged = OldVec =/= New#peer.vector,
            {min(?TRUST_MAX, T + ?TRUST_INCREMENT), VecChanged};
        error ->
            %% First contact — insert vector into the index immediately.
            kvex:add(Ix, Id, New#peer.vector),
            {?TRUST_INIT, false}
    end,
    case NeedsReindex of
        true ->
            %% Vector changed — rebuild the entire index for consistency.
            rebuild_kvex(State#state{
                peers = Peers#{Id => New#peer{
                    trust     = Trust,
                    last_seen = erlang:monotonic_time(millisecond)
                }}
            });
        false ->
            Updated = New#peer{
                trust     = Trust,
                last_seen = erlang:monotonic_time(millisecond)
            },
            State#state{peers = Peers#{Id => Updated}}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Decrease the trust score of a peer after a failed exchange.
%%
%% The score is floored at TRUST_MIN (0.0) and the peer stays in the
%% table.  Only stale eviction (see `cleanup_stale/2') removes peers.
%% @end
%%--------------------------------------------------------------------
-spec decay_trust(binary(), #state{}) -> #state{}.
decay_trust(PeerId, #state{peers = Peers} = State) ->
    case maps:find(PeerId, Peers) of
        {ok, #peer{trust = T} = Peer} ->
            NewTrust = max(?TRUST_MIN, T - ?TRUST_DECAY),
            State#state{peers = Peers#{PeerId => Peer#peer{trust = NewTrust}}};
        error ->
            %% Peer disappeared between the spawn and the result — ignore.
            State
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Merge a list of peers received from a remote node (transitive
%% discovery).
%%
%% Rules:
%%   • Skip ourselves (detected by matching our own ID).
%%   • Skip peers we already know (upsert_peer handles their updates).
%%   • Drop new peers when the peer list is at capacity (max_peers).
%%   • Newly added peers start with trust = 0 until they are contacted
%%     directly.
%% @end
%%--------------------------------------------------------------------
-spec merge_peers([#peer{}], #state{}) -> #state{}.
merge_peers([], State) ->
    State;
merge_peers([#peer{id = Id} | Rest], #state{id = Id} = State) ->
    %% This entry describes ourselves — skip.
    merge_peers(Rest, State);
merge_peers([P | Rest],
            #state{peers = Peers, max_peers = Max, kvex_ix = Ix} = State) ->
    case maps:is_key(P#peer.id, Peers) of
        true ->
            %% Already in the table — direct contact (upsert_peer) will
            %% refresh it when we gossip with it.
            merge_peers(Rest, State);
        false when map_size(Peers) >= Max ->
            %% Peer list at capacity — stop adding more.
            ?LOG_DEBUG("em_pop max_peers=~w reached, dropping new peer", [Max]),
            State;
        false ->
            %% New peer discovered transitively — index it and add to map.
            kvex:add(Ix, P#peer.id, P#peer.vector),
            NewPeer = P#peer{
                trust     = ?TRUST_MIN,
                last_seen = erlang:monotonic_time(millisecond)
            },
            State1 = State#state{peers = Peers#{P#peer.id => NewPeer}},
            merge_peers(Rest, State1)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Remove peers that have not been seen for more than Timeout ms.
%%
%% If any peers are removed the kvex index is rebuilt from scratch,
%% because kvex does not support incremental deletion.
%% @end
%%--------------------------------------------------------------------
-spec cleanup_stale(pos_integer(), #state{}) -> #state{}.
cleanup_stale(Timeout, #state{peers = Peers} = State) ->
    Now   = erlang:monotonic_time(millisecond),
    Alive = maps:filter(fun(_, #peer{last_seen = LS}) ->
        Now - LS < Timeout
    end, Peers),
    case map_size(Alive) =:= map_size(Peers) of
        true ->
            %% Nothing changed — avoid the index rebuild cost.
            State;
        false ->
            Evicted = map_size(Peers) - map_size(Alive),
            ?LOG_INFO("em_pop stale eviction: ~w peers removed", [Evicted]),
            rebuild_kvex(State#state{peers = Alive})
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Rebuild the kvex cosine-search index from the current peer map.
%%
%% Called after any peer removal or capability vector change.  kvex does
%% not support in-place deletion, so we delete the old index and create
%% a fresh one, re-inserting all surviving peers.
%% @end
%%--------------------------------------------------------------------
-spec rebuild_kvex(#state{}) -> #state{}.
rebuild_kvex(#state{peers = Peers, kvex_ix = Ix, vector = Vec} = State) ->
    kvex:delete(Ix),
    Dim = byte_size(Vec) div 4,
    {ok, NewIx} = kvex:new(Dim),
    maps:foreach(fun(Id, #peer{vector = V}) ->
        kvex:add(NewIx, Id, V)
    end, Peers),
    State#state{kvex_ix = NewIx}.

%%====================================================================
%% Internal — HTTP gossip transport
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Start (or restart) the Cowboy HTTP listener for this node.
%%
%% The listener reference is `{em_pop_listener, Port}' — unique per
%% port so multiple nodes can coexist in the same BEAM instance.
%%
%% If a stale listener is already bound to the port (e.g. after a
%% test crash) it is stopped and replaced transparently.
%% @end
%%--------------------------------------------------------------------
-spec start_listener(inet:port_number(), pid()) -> ok.
start_listener(Port, NodePid) ->
    Dispatch = cowboy_router:compile([
        %% Route all gossip POSTs to em_pop_http, passing our pid so
        %% the handler can forward the payload to us via handle_gossip/2.
        {'_', [{"/pop/gossip", em_pop_http, #{node => NodePid}}]}
    ]),
    do_start_listener(listener_ref(Port), Port, Dispatch).

-spec do_start_listener(term(), inet:port_number(), term()) -> ok.
do_start_listener(Ref, Port, Dispatch) ->
    case cowboy:start_clear(Ref, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            %% Stale listener (e.g. previous node on same port) — clean up and retry.
            ok = cowboy:stop_listener(Ref),
            do_start_listener(Ref, Port, Dispatch);
        {error, Reason} ->
            error({listener_start_failed, Port, Reason})
    end.

%% Returns the registered name used by Cowboy for this node's listener.
-spec listener_ref(inet:port_number()) -> {em_pop_listener, inet:port_number()}.
listener_ref(Port) -> {em_pop_listener, Port}.

%% Build the full URL for a peer's gossip endpoint.
-spec gossip_url(string(), inet:port_number()) -> string().
gossip_url(Host, Port) ->
    lists:flatten(io_lib:format("http://~s:~w/pop/gossip", [Host, Port])).

%%--------------------------------------------------------------------
%% @private
%% @doc HTTP POST the given payload map to Url, return the decoded response.
%%
%% Uses httpc (OTP built-in, part of `inets').  The response body is
%% expected to be a JSON-encoded map; anything else yields `{error, bad_json}'.
%% @end
%%--------------------------------------------------------------------
-spec http_post(string(), map()) -> {ok, map()} | {error, term()}.
http_post(Url, Payload) ->
    Body = iolist_to_binary(json:encode(Payload)),
    Req  = {Url, [], "application/json", Body},
    Opts = [{timeout, ?GOSSIP_HTTP_TIMEOUT}],
    case httpc:request(post, Req, Opts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try  {ok, json:decode(RespBody)}
            catch _:_ -> {error, bad_json}
            end;
        {ok, {{_, Code, _}, _, _}} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Internal — JSON serialisation
%%====================================================================
%%
%% All binary fields (id, vector) are base64-encoded for JSON transport.
%% The peer host is already a binary string so it is passed as-is.
%%

%% Serialise the local node's state for transmission.
-spec state_to_payload(#state{}) -> map().
state_to_payload(#state{id = Id, host = Host, port = Port,
                         query_port = QPort, name = Name,
                         vector = Vec, peers = Peers}) ->
    #{<<"id">>         => base64:encode(Id),
      <<"host">>       => Host,
      <<"port">>       => Port,
      <<"query_port">> => case QPort of undefined -> null; P -> P end,
      <<"name">>       => Name,
      <<"vector">>     => base64:encode(Vec),
      %% Include our own peer list so the remote can discover them too.
      <<"peers">>      => [peer_to_payload(P) || P <- maps:values(Peers)]}.

%% Serialise one #peer{} record for embedding in a payload.
-spec peer_to_payload(#peer{}) -> map().
peer_to_payload(#peer{id = Id, host = H, port = P, query_port = QP,
                      name = Name, vector = V, trust = T}) ->
    #{<<"id">>         => base64:encode(Id),
      <<"host">>       => H,
      <<"port">>       => P,
      <<"query_port">> => case QP of undefined -> null; Q -> Q end,
      <<"name">>       => Name,
      <<"vector">>     => base64:encode(V),
      <<"trust">>      => T}.

%% Deserialise the remote node's description from a gossip payload.
-spec payload_to_peer(map()) -> #peer{}.
payload_to_peer(#{<<"id">>     := Id,
                  <<"host">>   := Host,
                  <<"port">>   := Port,
                  <<"vector">> := Vec} = Map) ->
    QPort = case maps:get(<<"query_port">>, Map, null) of
        null -> undefined;
        P    -> P
    end,
    Name = maps:get(<<"name">>, Map, <<>>),
    #peer{
        id         = base64:decode(Id),
        host       = Host,
        port       = Port,
        query_port = QPort,
        name       = Name,
        vector     = base64:decode(Vec),
        %% Set last_seen to now — we just heard from this node.
        last_seen  = erlang:monotonic_time(millisecond)
    }.

%% Extract the list of peers embedded in a gossip payload.
-spec payload_to_peers(map()) -> [#peer{}].
payload_to_peers(#{<<"peers">> := List}) ->
    [payload_to_peer(P) || P <- List];
payload_to_peers(_) ->
    %% Defensive: ignore missing peers list rather than crashing.
    [].

%% Convert a #peer{} record to a plain map for the public API.
-spec peer_to_map(#peer{}) -> map().
peer_to_map(#peer{id = Id, host = H, port = P,
                  query_port = QP, name = Name,
                  vector = V, trust = T, last_seen = LS}) ->
    #{id         => Id,
      host       => H,
      port       => P,
      query_port => QP,
      name       => Name,
      vector     => V,
      trust      => T,
      last_seen  => LS}.

%% Convert a list of #peer{} records to plain maps.
-spec peers_to_maps([#peer{}]) -> [map()].
peers_to_maps(Peers) ->
    [peer_to_map(P) || P <- Peers].

%%====================================================================
%% Internal — utilities
%%====================================================================

%% Generate a cryptographically random 16-byte node identifier.
-spec generate_id() -> binary().
generate_id() ->
    crypto:strong_rand_bytes(16).

%% Return the first 4 bytes of a node ID as a lowercase hex string.
%% Used in log messages to keep IDs readable without being too long.
-spec short_id(binary()) -> binary().
short_id(Id) when byte_size(Id) >= 4 ->
    <<Short:4/binary, _/binary>> = Id,
    binary:encode_hex(Short, lowercase);
short_id(Id) ->
    binary:encode_hex(Id, lowercase).
