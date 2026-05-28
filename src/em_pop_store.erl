%%%-------------------------------------------------------------------
%%% @doc
%%% em_pop_store — DETS-backed peer table persistence.
%%%
%%% Provides open/close/save/load against a named DETS table.
%%% Called exclusively by em_pop_node.
%%%
%%% One table per node, named `em_pop_<agent_name>'.
%%% File: `<persist_dir>/em_pop_<agent_name>.peers'.
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_store).
-export([open/2, close/1, save/2, load/1]).

%%--------------------------------------------------------------------
%% @doc Open (or create) the DETS table.
%%
%% Name — unique atom per node, e.g. `em_pop_hackernews_filter'
%% Dir  — directory path string; created automatically if absent
%% @end
%%--------------------------------------------------------------------
-spec open(atom(), string()) -> {ok, atom()} | {error, term()}.
open(Name, Dir) ->
    ok = filelib:ensure_dir(Dir ++ "/"),
    File = filename:join(Dir, atom_to_list(Name) ++ ".peers"),
    dets:open_file(Name, [{file, File}, {type, set}]).

%%--------------------------------------------------------------------
%% @doc Close the DETS table.
%%
%% Errors (e.g. already closed) are returned as-is; callers may ignore.
%% @end
%%--------------------------------------------------------------------
-spec close(atom()) -> ok | {error, term()}.
close(Name) -> dets:close(Name).

%%--------------------------------------------------------------------
%% @doc Replace the entire table with the current peer map.
%%
%% Peers is #{PeerId => #peer{}} — the internal em_pop_node peer map.
%% @end
%%--------------------------------------------------------------------
-spec save(atom(), #{binary() => term()}) -> ok | {error, term()}.
save(Name, Peers) ->
    dets:delete_all_objects(Name),
    dets:insert(Name, maps:to_list(Peers)).

%%--------------------------------------------------------------------
%% @doc Read all saved peers back as a map.
%%
%% Returns #{} on any error so the caller never needs to handle failure.
%% @end
%%--------------------------------------------------------------------
-spec load(atom()) -> #{binary() => term()}.
load(Name) ->
    case dets:match(Name, '$1') of
        {error, _} -> #{};
        Rows       -> maps:from_list([P || [P] <- Rows])
    end.
