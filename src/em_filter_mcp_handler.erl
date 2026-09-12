%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter_mcp_handler — MCP Streamable HTTP handler for a single
%%% em_filter agent.
%%%
%%% Implements the Model Context Protocol (MCP) Streamable HTTP
%%% transport (spec 2025-03-26) on a single /mcp endpoint, exposing
%%% this agent's own `handle/2' as one MCP tool named after the agent.
%%%
%%% This lets any em_filter-based agent be plugged directly into an
%%% MCP client (Claude, Cursor, VS Code…) without going through
%%% em_disco at all — mirrors em_disco's own central em_disco_mcp_handler
%%% (which fans a query out to every agent connected to that disco
%%% node), but scoped to just this one agent's handler.
%%%
%%% === Transport ===
%%%
%%%   POST /mcp  Content-Type: application/json
%%%     -> single JSON-RPC response   (Accept: application/json)
%%%     -> SSE stream                  (Accept: text/event-stream)
%%%
%%%   GET  /mcp
%%%     -> SSE stream announcing the POST endpoint (MCP spec requirement)
%%%
%%% === JSON-RPC methods exposed ===
%%%
%%%   initialize                 -> server info + capabilities declaration
%%%   notifications/initialized  -> ack (no-op)
%%%   tools/list                 -> a single tool named after this agent
%%%   tools/call                 -> forwards the query to this agent's own
%%%                                  handler via `{http_query, Query}',
%%%                                  the same call em_filter_http uses
%%%
%%% The Cowboy route options map MUST contain:
%%%   `server'       => atom()     — registered name of the em_filter_server
%%%   `name'         => binary()   — agent name, used as the MCP tool name
%%%   `capabilities' => [binary()] — announced capabilities (tool description)
%%%
%%% Reuses the same optional Bearer auth as em_filter_http (the
%%% `auth_token' application env key), so an MCP endpoint enabled
%%% alongside `/agent/query' shares one access policy.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter_mcp_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MCP_VERSION,     <<"2025-03-26">>).
-define(SERVER_VERSION,  <<"1.0.0">>).
-define(QUERY_TIMEOUT_MS, 30_000).

%%====================================================================
%% Cowboy entry point
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Cowboy request entry point for `GET /mcp' and `POST /mcp'.
%%
%% Checks the same optional Bearer token as em_filter_http, then
%% routes to `handle/3'.
%% @end
%%--------------------------------------------------------------------
init(Req0, State) ->
    case em_filter_authz(Req0) of
        true  ->
            Method = cowboy_req:method(Req0),
            handle(Method, Req0, State);
        false ->
            {ok, cowboy_req:reply(401, #{}, <<"unauthorized">>, Req0), State}
    end.

%% @private Same optional Bearer-token check as em_filter_http.
em_filter_authz(Req) ->
    case application:get_env(em_filter, auth_token, undefined) of
        undefined -> true;
        Tok ->
            case cowboy_req:header(<<"authorization">>, Req) of
                <<"Bearer ", T/binary>> when T =:= Tok -> true;
                _ -> false
            end
    end.

%% @private
%% @doc Open an SSE stream and send the `endpoint' event.
%%
%% Required by the MCP Streamable HTTP spec to announce the POST
%% endpoint to the client. The stream is closed immediately after —
%% clients POST their JSON-RPC requests separately.
%% @end
handle(<<"GET">>, Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>                 => <<"text/event-stream">>,
        <<"cache-control">>                => <<"no-cache">>,
        <<"connection">>                   => <<"keep-alive">>,
        <<"access-control-allow-origin">>  => <<"*">>
    }, Req0),
    send_sse(Req, <<"endpoint">>, <<"/mcp">>),
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State};

%% @private
%% @doc Parse the JSON-RPC body and dispatch.
%%
%% Checks the `Accept' header to decide the response mode: plain JSON
%% (`application/json') or SSE (`text/event-stream'). Batch requests
%% (JSON arrays) always use plain JSON regardless of `Accept'.
%% @end
handle(<<"POST">>, Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 64_000, period => 5_000}),
    Accept = cowboy_req:header(<<"accept">>, Req1, <<"application/json">>),
    UseSSE = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,

    case parse_jsonrpc(Body) of
        {ok, Requests} when is_list(Requests) ->
            %% Batch request
            Responses = [dispatch(R, State) || R <- Requests],
            reply_json(json:encode(Responses), Req1, State);
        {ok, Request} ->
            case UseSSE of
                true  -> handle_sse(Request, Req1, State);
                false -> handle_json(Request, Req1, State)
            end;
        {error, _} ->
            Err = error_response(null, -32700, <<"Parse error">>),
            reply_json(json:encode(Err), Req1, State)
    end;

handle(<<"OPTIONS">>, Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State};

handle(_, Req0, State) ->
    Req = cowboy_req:reply(405,
        #{<<"content-type">> => <<"application/json">>},
        json:encode(#{<<"error">> => <<"method not allowed">>}), Req0),
    {ok, Req, State}.

%%====================================================================
%% Response modes
%%====================================================================

%% @private
%% @doc Dispatch a single JSON-RPC request and reply with plain JSON.
%% @end
handle_json(Request, Req0, State) ->
    Response = dispatch(Request, State),
    reply_json(json:encode(Response), Req0, State).

%% @private
%% @doc Dispatch a single JSON-RPC request and stream the response as
%% a single SSE `message' event.
%% @end
handle_sse(Request, Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{
        <<"content-type">>                => <<"text/event-stream">>,
        <<"cache-control">>               => <<"no-cache">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Req0),
    Response = dispatch(Request, State),
    send_sse(Req, <<"message">>, iolist_to_binary(json:encode(Response))),
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State}.

%% @private
%% @doc Send a 200 JSON response with CORS headers.
%% @end
reply_json(Body, Req0, State) ->
    Req = cowboy_req:reply(200,
        #{<<"content-type">>                => <<"application/json">>,
          <<"access-control-allow-origin">> => <<"*">>},
        Body, Req0),
    {ok, Req, State}.

%%====================================================================
%% JSON-RPC dispatch
%%====================================================================

%% @private
-spec dispatch(map(), map()) -> map() | null.
dispatch(#{<<"method">> := <<"initialize">>, <<"id">> := Id}, #{name := Name}) ->
    result(Id, #{
        <<"protocolVersion">> => ?MCP_VERSION,
        <<"serverInfo">>      => #{
            <<"name">>    => Name,
            <<"version">> => ?SERVER_VERSION
        },
        <<"capabilities">> => #{
            <<"tools">> => #{<<"listChanged">> => false}
        }
    });

dispatch(#{<<"method">> := <<"notifications/initialized">>}, _State) ->
    %% Notification — no response needed, return null for internal use.
    null;

dispatch(#{<<"method">> := <<"tools/list">>, <<"id">> := Id}, State) ->
    result(Id, #{<<"tools">> => [tool_schema(State)]});

dispatch(#{<<"method">> := <<"tools/call">>,
           <<"id">>     := Id,
           <<"params">> := #{<<"name">> := ReqName, <<"arguments">> := Args}},
         #{name := ToolName} = State) when ReqName =:= ToolName ->
    call_tool(Id, Args, State);

dispatch(#{<<"method">> := <<"tools/call">>,
           <<"id">>     := Id,
           <<"params">> := #{<<"name">> := ReqName}}, _State) ->
    error_response(Id, -32601, iolist_to_binary(["Unknown tool: ", ReqName]));

dispatch(#{<<"id">> := Id, <<"method">> := Method}, _State) ->
    error_response(Id, -32601,
        iolist_to_binary(["Method not found: ", Method]));

dispatch(_, _State) ->
    error_response(null, -32600, <<"Invalid Request">>).

%%====================================================================
%% Tool implementation
%%====================================================================

%% @private
%% @doc Forward the query to this agent's own handler via the same
%% `{http_query, Query}' call em_filter_http uses, and wrap the
%% (already-JSON) result as MCP tool content.
%% @end
-spec call_tool(term(), map(), map()) -> map().
call_tool(Id, Args, #{server := ServerName}) ->
    Query = maps:get(<<"query">>, Args, <<>>),
    case Query of
        <<>> ->
            error_response(Id, -32602, <<"Missing required argument: query">>);
        _ ->
            CallResult = try gen_server:call(ServerName, {http_query, Query}, ?QUERY_TIMEOUT_MS)
                         catch exit:ExitReason -> {error, ExitReason}
                         end,
            case CallResult of
                {ok, RawResult} ->
                    Decoded = try json:decode(RawResult)
                              catch _:_ -> RawResult end,
                    result(Id, #{
                        <<"content">> => [#{
                            <<"type">> => <<"text">>,
                            <<"text">> => iolist_to_binary(json:encode(Decoded))
                        }]
                    });
                {error, Reason} ->
                    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
                    error_response(Id, -32000, Msg)
            end
    end.

%%====================================================================
%% Tool schema
%%====================================================================

%% @private
%% @doc A single MCP tool named after this agent. Its description
%% lists the agent's announced capabilities so an LLM client can tell
%% at a glance what it is good for.
%% @end
tool_schema(#{name := Name, capabilities := Caps}) ->
    #{
        <<"name">>        => Name,
        <<"description">> => tool_description(Name, Caps),
        <<"inputSchema">> => #{
            <<"type">>       => <<"object">>,
            <<"properties">> => #{
                <<"query">> => #{
                    <<"type">>        => <<"string">>,
                    <<"description">> => <<"The query to send to this agent">>
                }
            },
            <<"required">> => [<<"query">>]
        }
    }.

%% @private
tool_description(Name, []) ->
    iolist_to_binary(["Query the '", Name, "' Emergence agent."]);
tool_description(Name, Caps) ->
    iolist_to_binary(["Query the '", Name,
        "' Emergence agent. Capabilities: ",
        lists:join(<<", ">>, Caps), "."]).

%%====================================================================
%% JSON-RPC helpers
%%====================================================================

%% @private
-spec result(term(), term()) -> map().
result(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">>      => Id,
      <<"result">>  => Result}.

%% @private
-spec error_response(term(), integer(), binary()) -> map().
error_response(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>,
      <<"id">>      => Id,
      <<"error">>   => #{
          <<"code">>    => Code,
          <<"message">> => Message
      }}.

%% @private
-spec parse_jsonrpc(binary()) -> {ok, map() | list()} | {error, term()}.
parse_jsonrpc(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, invalid_json} end.

%%====================================================================
%% SSE helper
%%====================================================================

%% @private
%% @doc Write a single `event: Event\ndata: Data\n\n' frame to the stream.
%% @end
send_sse(Req, Event, Data) ->
    Frame = <<"event: ", Event/binary, "\ndata: ", Data/binary, "\n\n">>,
    cowboy_req:stream_body(Frame, nofin, Req).

%%====================================================================
%% CORS headers
%%====================================================================

%% @private
%% @doc Return CORS headers allowing all origins, GET/POST/OPTIONS
%% methods, and content-type/accept/authorization request headers.
%% @end
cors_headers() ->
    #{<<"access-control-allow-origin">>  => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> =>
          <<"content-type, accept, authorization">>}.
