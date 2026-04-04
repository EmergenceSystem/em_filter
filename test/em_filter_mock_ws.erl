%%%-------------------------------------------------------------------
%%% @doc
%%% Cowboy WebSocket handler for the em_disco mock.
%%%
%%% Implements the server side of the em_disco agent handshake:
%%%   register → agent_hello → query/result cycle.
%%%
%%% Token validation is intentionally skipped — the mock accepts any
%%% connection regardless of the `token' query parameter.
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_mock_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

-record(ws_state, {
    name       = undefined :: binary() | undefined,
    registered = false     :: boolean()
}).

init(Req, _Opts) ->
    {cowboy_websocket, Req, #ws_state{}, #{idle_timeout => 60000}}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Data}, State) ->
    case json:decode(Data) of
        #{<<"action">> := <<"register">>, <<"name">> := Name} ->
            Reply = json:encode(#{
                <<"status">> => <<"ok">>,
                <<"action">> => <<"registered">>
            }),
            {reply, {text, Reply}, State#ws_state{name = Name}};

        #{<<"action">> := <<"agent_hello">>, <<"capabilities">> := Caps}
          when State#ws_state.name =/= undefined ->
            Name = State#ws_state.name,
            ets:insert(mock_disco_agents, {Name, Caps, self()}),
            Reply = json:encode(#{
                <<"status">>       => <<"ok">>,
                <<"action">>       => <<"agent_registered">>,
                <<"capabilities">> => Caps
            }),
            {reply, {text, Reply}, State#ws_state{registered = true}};

        #{<<"action">> := <<"result">>, <<"id">> := Id, <<"data">> := Result} ->
            case ets:lookup(mock_disco_queries, Id) of
                [{Id, CallerPid}] -> CallerPid ! {query_result, Id, Result};
                []                -> ok
            end,
            {ok, State};

        _ ->
            {ok, State}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({send, Data}, State) ->
    {reply, {text, Data}, State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #ws_state{name = Name, registered = true}) ->
    ets:delete(mock_disco_agents, Name),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.
