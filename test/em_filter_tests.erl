-module(em_filter_tests).
-include_lib("eunit/include/eunit.hrl").

find_port_test() ->
    {ok, Port} = em_filter:find_port(),
    ?assert(Port >= 8081),
    ?assert(Port =< 9000).

