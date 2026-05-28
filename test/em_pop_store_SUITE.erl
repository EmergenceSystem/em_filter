-module(em_pop_store_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([save_and_load/1, load_empty_file/1,
         save_overwrites/1, close_idempotent/1]).

all() -> [save_and_load, load_empty_file, save_overwrites, close_idempotent].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

init_per_testcase(TestCase, Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config),
                        atom_to_list(TestCase)),
    [{store_dir, Dir}, {store_name, TestCase} | Config].

end_per_testcase(_TestCase, Config) ->
    Name = proplists:get_value(store_name, Config),
    catch dets:close(Name),
    Config.

%% open → save map → close → reopen → load returns the same map
save_and_load(Config) ->
    Dir  = proplists:get_value(store_dir,  Config),
    Name = proplists:get_value(store_name, Config),
    {ok, _} = em_pop_store:open(Name, Dir),
    Peers = #{<<"id1">> => #{host => "h1", port => 4200},
              <<"id2">> => #{host => "h2", port => 4201}},
    ok = em_pop_store:save(Name, Peers),
    ok = em_pop_store:close(Name),
    {ok, _} = em_pop_store:open(Name, Dir),
    Loaded = em_pop_store:load(Name),
    ok = em_pop_store:close(Name),
    ?assertEqual(Peers, Loaded).

%% fresh table → load → empty map
load_empty_file(Config) ->
    Dir  = proplists:get_value(store_dir,  Config),
    Name = proplists:get_value(store_name, Config),
    {ok, _} = em_pop_store:open(Name, Dir),
    Loaded = em_pop_store:load(Name),
    ok = em_pop_store:close(Name),
    ?assertEqual(#{}, Loaded).

%% save 3 items, then save 1 item → load returns only 1 item
save_overwrites(Config) ->
    Dir  = proplists:get_value(store_dir,  Config),
    Name = proplists:get_value(store_name, Config),
    {ok, _} = em_pop_store:open(Name, Dir),
    Peers3 = #{<<"id1">> => #{host => "h1", port => 4200},
               <<"id2">> => #{host => "h2", port => 4201},
               <<"id3">> => #{host => "h3", port => 4202}},
    ok = em_pop_store:save(Name, Peers3),
    Peers1 = #{<<"id1">> => #{host => "h1", port => 4200}},
    ok = em_pop_store:save(Name, Peers1),
    Loaded = em_pop_store:load(Name),
    ok = em_pop_store:close(Name),
    ?assertEqual(Peers1, Loaded).

%% double close does not crash
close_idempotent(Config) ->
    Dir  = proplists:get_value(store_dir,  Config),
    Name = proplists:get_value(store_name, Config),
    {ok, _} = em_pop_store:open(Name, Dir),
    ok = em_pop_store:close(Name),
    _ = em_pop_store:close(Name),   %% {error, not_owner} is acceptable
    ok.
