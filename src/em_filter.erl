%%%-------------------------------------------------------------------
%%% @doc
%%% `em_filter' - Library for registering Emergence filters
%%%
%%% This module provides functions for:
%%% - Finding an available port for a filter service
%%% - Registering a filter with a discovery service
%%%
%%% @author Steve Roques
%%% @version 0.1.3
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter).

%% Public API
-export([find_port/0, register_filter/1, start_filter/3]).

%% Type specifications
-type port_number() :: 1..65535.
-type filter_url() :: string().

%%====================================================================
%% API Functions
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Finds an available TCP port for the filter service.
%% Searches for a free port in the range 8081-9000.
%%
%% @return {ok, Port} if an available port is found, or
%%         {error, no_ports_available} if no port is available
%% @end
%%--------------------------------------------------------------------
-spec find_port() -> {ok, port_number()} | {error, no_ports_available}.
find_port() ->
    find_port_in_range(8081, 9000).

%%--------------------------------------------------------------------
%% @doc Registers a filter with the discovery service.
%%
%% This function sends an HTTP POST request to the discovery service at
%% http://localhost:8080/register with the filter information in JSON format.
%%
%% @param FilterUrl URL of the filter service to register
%% @return {ok, registered} if registration is successful, or
%%         {error, Reason} if registration fails
%% @end
%%--------------------------------------------------------------------
-spec register_filter(filter_url()) -> {ok, registered} | {error, term()}.
register_filter(FilterUrl) ->
    DiscoUrl = embryo:get_em_disco_url(),
    RegisterUrl = DiscoUrl ++ "/register",
    io:format("Disco URL: ~p~n", [DiscoUrl]),
    io:format("Register URL: ~p~n", [RegisterUrl]),
    io:format("Filter URL: ~p~n", [FilterUrl]),
    FilterUrlBinary = list_to_binary(FilterUrl),
    Body = jsone:encode(#{
        url => FilterUrlBinary,
        name => <<"Emergence Filter">>,
        description => <<"Library simplifies the creation of filters.">>
    }),
    Headers = [{"Content-Type", "application/json"}],
    Options = [{body_format, binary}],
    case httpc:request(post, {RegisterUrl, Headers, "application/json", Body}, [], Options) of
        {ok, {{_, 200, _}, _, _}} ->
            io:format("Successfully registered filter~n"),
            {ok, registered};
        {ok, {{_, StatusCode, _}, _, ResponseBody}} ->
            io:format("Failed to register filter. Status: ~p, Body: ~p~n", [StatusCode, ResponseBody]),
            {error, {status, StatusCode}};
        {error, Reason} ->
            io:format("Error registering filter: ~p~n", [Reason]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc Searches for an available port within a specified range.
%%
%% @private
%% @param Min Lower bound of the port range
%% @param Max Upper bound of the port range
%% @return {ok, Port} if an available port is found, or
%%         {error, no_ports_available} if no port is available
%% @end
%%--------------------------------------------------------------------
-spec find_port_in_range(port_number(), port_number()) -> {ok, port_number()} | {error, no_ports_available}.
find_port_in_range(Min, Max) when Min =< Max ->
    Port = Min,
    case gen_tcp:listen(Port, []) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            {ok, Port};
        {error, _} ->
            find_port_in_range(Min + 1, Max)
    end;

find_port_in_range(_, _) ->
    {error, no_ports_available}.

-spec start_filter(atom(), module(), list()) -> {ok, pid()} | {error, term()}.
start_filter(FilterName, HandlerModule, Options) ->
    {ok, Port} = find_port(),
    
    {ok, Pid} = em_filter_sup:start_link(FilterName, HandlerModule, Port, Options),
    
    FilterUrl = "http://localhost:" ++ integer_to_list(Port),
    
    register_filter(FilterUrl),
    
    {ok, Pid}.
