-module(em_filter_tests).
-include_lib("eunit/include/eunit.hrl").

%% Start the em_filter application before running tests,
%% stop it cleanly afterwards.
start_stop_test_() ->
    {setup,
     fun()  -> application:ensure_all_started(em_filter) end,
     fun(_) -> application:stop(em_filter) end,
     fun(_) ->
         [
             ?_test(begin
                 {ok, Pid} = em_filter:start_filter(test_filter, ?MODULE),
                 ?assert(is_pid(Pid)),
                 ok = em_filter:stop_filter(test_filter)
             end)
         ]
     end}.

