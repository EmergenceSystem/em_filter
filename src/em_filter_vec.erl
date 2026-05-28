%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter_vec — Capability list → semantic f32 vector
%%%
%%% Converts an agent's capability list into a unit-norm f32 binary
%%% vector suitable for cosine-similarity routing in em_pop.
%%%
%%% === Algorithm ===
%%%
%%%   1. Each capability string is normalised to a binary (atoms and
%%%      char-lists are accepted for convenience).
%%%   2. It is hashed via `erlang:phash2/2' to a slot index in
%%%      `[0, Dim-1]'.  phash2 is deterministic across BEAM restarts
%%%      for the same Erlang major version, so the same capability
%%%      always maps to the same slot.
%%%   3. The slot's weight is incremented by 1.0 (additive: two
%%%      capabilities that collide in the same slot reinforce each
%%%      other rather than cancelling).
%%%   4. The resulting weight vector is L2-normalised to unit length
%%%      so that cosine similarity is always well-defined and lies in
%%%      [-1, 1].
%%%
%%% === Empty capability list ===
%%%
%%%   A uniform unit vector is returned (all slots equal, total norm = 1).
%%%   This avoids a zero vector which has no well-defined cosine.
%%%
%%% === Dimension ===
%%%
%%%   Default is 64 floats (256 bytes).  This gives a good trade-off
%%%   between precision (hash collision probability ≈ 1/64 per pair)
%%%   and memory cost.  Pass an explicit `Dim' to `from_capabilities/2'
%%%   when finer resolution is needed (e.g. 128 or 256).
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_vec).
-export([from_capabilities/1, from_capabilities/2]).

%% Number of f32 floats in the default output vector.
-define(DEFAULT_DIM, 64).

%%--------------------------------------------------------------------
%% @doc Derive a 64-dimension unit-norm f32 vector from a capability list.
%%
%% Equivalent to `from_capabilities(Caps, 64)'.
%% @end
%%--------------------------------------------------------------------
-spec from_capabilities([binary() | atom() | string()]) -> binary().
from_capabilities(Caps) ->
    from_capabilities(Caps, ?DEFAULT_DIM).

%%--------------------------------------------------------------------
%% @doc Derive a Dim-dimension unit-norm f32 vector from a capability list.
%%
%% The output is a flat binary of `Dim' IEEE-754 single-precision floats
%% in little-endian byte order, as expected by kvex.
%%
%% Example:
%%   Vec = em_filter_vec:from_capabilities([<<"rss">>, <<"search">>], 64).
%%   %% Vec is a 256-byte binary, unit norm, usable directly with kvex.
%% @end
%%--------------------------------------------------------------------
-spec from_capabilities([binary() | atom() | string()], pos_integer()) ->
    binary().
from_capabilities([], Dim) ->
    %% Empty list → all slots equal → uniform unit vector.
    %% Each element = 1/sqrt(Dim) so that sum_of_squares = 1.
    Uniform = 1.0 / math:sqrt(float(Dim)),
    << <<Uniform:32/float-little>> || _ <- lists:seq(1, Dim) >>;
from_capabilities(Caps, Dim) ->
    %% Step 1 — accumulate slot weights in a sparse map.
    %% Using a map avoids allocating a full Dim-element list upfront.
    Slots = lists:foldl(fun(Cap, Acc) ->
        Key = cap_key(Cap),
        %% phash2(Key, Dim) returns an integer in [0, Dim-1].
        Idx = erlang:phash2(Key, Dim),
        %% Increment the slot, defaulting to 1.0 on first occurrence.
        maps:update_with(Idx, fun(V) -> V + 1.0 end, 1.0, Acc)
    end, #{}, Caps),

    %% Step 2 — materialise the dense float list in slot order.
    Floats = [maps:get(I, Slots, 0.0) || I <- lists:seq(0, Dim - 1)],

    %% Step 3 — L2-normalise so that ||vector|| = 1.
    SumSq = lists:foldl(fun(F, S) -> S + F * F end, 0.0, Floats),
    Norm  = math:sqrt(SumSq),
    << <<(F / Norm):32/float-little>> || F <- Floats >>.

%%====================================================================
%% Private helpers
%%====================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Normalise a capability value to a binary key for hashing.
%%
%% Accepts atoms, binaries, and char-lists so callers do not need to
%% pre-convert before building the capability list.
%% @end
%%--------------------------------------------------------------------
-spec cap_key(binary() | atom() | string()) -> binary().
cap_key(A) when is_atom(A)   -> atom_to_binary(A, utf8);
cap_key(B) when is_binary(B) -> B;
cap_key(L) when is_list(L)   -> list_to_binary(L).
