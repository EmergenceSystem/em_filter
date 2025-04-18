-module(em_filter_server).
-behaviour(gen_server).

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    handler_module,
    port,
    cowboy_ref
}).

start_link(HandlerModule, Port) ->
    {ok, _} = application:ensure_all_started(cowboy),
    gen_server:start_link({local, HandlerModule}, ?MODULE, {HandlerModule, Port}, []).

init({HandlerModule, Port}) ->
    process_flag(trap_exit, true),
    
    %% Configuration du routage Cowboy
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/query", HandlerModule, []}
        ]}
    ]),
    
    %% Démarrage de Cowboy avec gestion des erreurs
    case cowboy:start_clear(http_listener, [{port, Port}], #{env => #{dispatch => Dispatch}}) of
        {ok, Ref} ->
            io:format("Filter registrer: http://localhost:~p/query~n", [Port]),
            em_filter:register_filter(io_lib:format("http://localhost:~p/query", [Port])),
            {ok, #state{
                handler_module = HandlerModule,
                port = Port,
                cowboy_ref = Ref
            }};
        {error, Reason} ->
            {stop, {cowboy_start_error, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = _Port, cowboy_ref = Ref}) ->
    ok = cowboy:stop_listener(Ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
