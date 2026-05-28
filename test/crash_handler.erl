-module(crash_handler).
-export([handle/2]).
-spec handle(binary(), map()) -> {binary(), map()}.
handle(_Query, _Memory) ->
    error(intentional_crash).
