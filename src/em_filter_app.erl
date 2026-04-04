%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter OTP Application Callback
%%%
%%% Entry point for the `em_filter' OTP application.
%%% Starts the top-level supervisor (`em_filter_sup') which manages
%%% all filter worker processes.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_app).
-behaviour(application).

-export([start/2, stop/1]).

%%--------------------------------------------------------------------
%% @doc Starts the em_filter application.
%%
%% Called automatically by the OTP application controller.
%% Delegates to `em_filter_sup:start_link/0'.
%%
%% @param StartType Start type as defined by the OTP application behaviour.
%% @param StartArgs Arguments from the `mod' key of the app descriptor
%%                  (unused).
%% @return `{ok, Pid}' where `Pid' is the supervisor pid.
%% @end
%%--------------------------------------------------------------------
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    logger:add_primary_filter(no_progress,
        {fun logger_filters:progress/2, stop}),
    em_filter_sup:start_link().

%%--------------------------------------------------------------------
%% @doc Stops the em_filter application.
%%
%% Called automatically by the OTP application controller after the
%% supervision tree has been shut down.
%%
%% @param State Application state returned by `start/2' (unused).
%% @return `ok'.
%% @end
%%--------------------------------------------------------------------
-spec stop(term()) -> ok.
stop(_State) ->
    ok.
