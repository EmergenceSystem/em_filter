-module(em_filter_server).
-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    handler_module,
    options,
    port
}).

%%====================================================================
%% API functions
%%====================================================================

start_link(HandlerModule, Port, Options) ->
    gen_server:start_link({local, HandlerModule}, ?MODULE, {HandlerModule, Port, Options}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({HandlerModule, Port, Options}) ->
    process_flag(trap_exit, true),
    
    {ok, _} = inets:start(httpd, [
        {port, Port},
        {server_name, atom_to_list(HandlerModule)},
        {server_root, "."},
        {document_root, "."},
        {modules, [mod_get, HandlerModule]}
    ]),
    
    io:format("Filter server started on port ~p with handler ~p~n", [Port, HandlerModule]),
    
    {ok, #state{
        handler_module = HandlerModule,
        options = Options,
        port = Port
    }}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port}) ->
    inets:stop(httpd, {port, Port}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
