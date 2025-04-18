%%%-------------------------------------------------------------------
%%% @doc
%%% `em_filter' - Library for registering Emergence filters
%%%
%%% This module provides functions for:
%%% - Finding an available port for a filter service
%%% - Registering a filter with a discovery service
%%%
%%% @author Steve Roques
%%% @version 0.1.5
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter).

%% Public API
-export([find_port/0, register_filter/1, start_filter/3]).

-export([
    parse_string/1,
    extract_elements/2,
    get_text/1,
    extract_attribute/2,
    clean_text/3,
    ensure_binary/1,
    safe_binary_replace/3,
    decode_html_entities/1,
    decode_numeric_entities/1,
    decode_hex_entities/1,
    decode_named_entities/1,
    resolve_named_entity/1,
    should_skip_link/2
]).

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

parse_string(Html) when is_binary(Html) ->
    try
        CleanHtml = clean_html(Html),
        {ok, CleanHtml}
    catch
        _:Reason ->
            io:format("HTML cleaning failed: ~p~n", [Reason]),
            {error, cleaning_failed}
    end;
parse_string(Html) when is_list(Html) ->
    parse_string(list_to_binary(Html)).

clean_html(Html) ->
    % Simple cleaning: remove script tags and their content
    re:replace(Html, "<script[^>]*>.*?</script>", "", [global, dotall, {return, binary}]).

extract_elements(Html, Selector) ->
    case Selector of
        "li.b_algo" ->
            re:run(Html, "<li[^>]*class=['\"]b_algo['\"][^>]*>(.*?)</li>", [global, dotall, {capture, all_but_first, binary}]);
        "div a" ->
            re:run(Html, "<a[^>]*>(.*?)</a>", [global, dotall, {capture, all, binary}]);
        "div p" ->
            re:run(Html, "<p[^>]*>(.*?)</p>", [global, dotall, {capture, all, binary}]);
        ".algoSlug_icon" ->
            re:run(Html, "class=['\"]algoSlug_icon['\"][^>]*>(.*?)<", [global, dotall, {capture, all, binary}]);
        ".news_dt" ->
            re:run(Html, "class=['\"]news_dt['\"][^>]*>(.*?)<", [global, dotall, {capture, all, binary}]);
        _ ->
            {match, []}
    end.

get_text(Element) ->
    % Simple text extraction: remove all HTML tags
    re:replace(Element, "<[^>]*>", "", [global, {return, binary}]).

extract_attribute(Element, Attribute) ->
    case re:run(Element, Attribute ++ "=['\"]([^'\"]*)['\"]", [{capture, all_but_first, binary}]) of
        {match, [Value]} -> {ok, Value};
        _ -> error
    end.

should_skip_link(Link, ExcludedContent) ->
    IsExcluded = lists:any(fun(Excluded) ->
        binary:match(Link, list_to_binary(Excluded)) =/= nomatch
    end, ExcludedContent),
    IsExcluded orelse binary:match(Link, <<"http">>) =/= {0,4}.

clean_text(DescText0, IconText0, DtText0) ->
    DescText = ensure_binary(DescText0),
    IconText = ensure_binary(IconText0),
    DtText = ensure_binary(DtText0),
    Text1 = safe_binary_replace(DescText, IconText, <<>>),
    Text2 = safe_binary_replace(Text1, DtText, <<>>),
    Text3 = safe_binary_replace(Text2, <<" . ">>, <<>>),
    decode_html_entities(Text3).

ensure_binary(Text) when is_binary(Text) -> Text;
ensure_binary(_) -> <<>>.

safe_binary_replace(Subject, Pattern, Replacement) ->
    try
        case byte_size(Pattern) of
            0 -> Subject;
            _ -> binary:replace(Subject, Pattern, Replacement, [global])
        end
    catch
        _:_ -> Subject
    end.

decode_html_entities(Text) ->
    Text1 = decode_numeric_entities(Text),
    Text2 = decode_hex_entities(Text1),
    decode_named_entities(Text2).

decode_numeric_entities(Text) ->
    {ok, Pattern} = re:compile(<<"&#([0-9]+);">>),
    case re:run(Text, Pattern, [{capture, all, binary}, global]) of
        {match, Matches} ->
            lists:foldl(fun([Full, NumBin], Acc) ->
                try
                    Num = binary_to_integer(NumBin),
                    Char = unicode:characters_to_binary([Num], unicode, utf8),
                    safe_binary_replace(Acc, Full, Char)
                catch
                    _:_ -> Acc
                end
            end, Text, Matches);
        nomatch ->
            Text
    end.

decode_hex_entities(Text) ->
    {ok, Pattern} = re:compile(<<"&#x([0-9A-Fa-f]+);">>),
    case re:run(Text, Pattern, [{capture, all, binary}, global]) of
        {match, Matches} ->
            lists:foldl(fun([Full, HexBin], Acc) ->
                try
                    Num = binary_to_integer(HexBin, 16),
                    Char = unicode:characters_to_binary([Num], unicode, utf8),
                    safe_binary_replace(Acc, Full, Char)
                catch
                    _:_ -> Acc
                end
            end, Text, Matches);
        nomatch ->
            Text
    end.

decode_named_entities(Text) ->
    try
        mochiweb_html:decode_entities(Text)
    catch
        _:_ ->
            {ok, Pattern} = re:compile(<<"&([a-zA-Z]+);">>),
            case re:run(Text, Pattern, [{capture, all, binary}, global]) of
                {match, Matches} ->
                    lists:foldl(fun([Full, Name], Acc) ->
                        Entity = resolve_named_entity(Name),
                        case Entity of
                            undefined -> Acc;
                            _ -> safe_binary_replace(Acc, Full, Entity)
                        end
                    end, Text, Matches);
                nomatch ->
                    Text
            end
    end.

resolve_named_entity(<<"nbsp">>) -> <<" ">>;
resolve_named_entity(<<"amp">>) -> <<"&">>;
resolve_named_entity(<<"lt">>) -> <<"<">>;
resolve_named_entity(<<"gt">>) -> <<">">>;
resolve_named_entity(<<"quot">>) -> <<"\"">>;
resolve_named_entity(<<"apos">>) -> <<"'">>;
resolve_named_entity(<<"eacute">>) -> <<"é">>;
resolve_named_entity(<<"egrave">>) -> <<"è">>;
resolve_named_entity(<<"agrave">>) -> <<"à">>;
resolve_named_entity(<<"ccedil">>) -> <<"ç">>;
resolve_named_entity(_) -> undefined.
