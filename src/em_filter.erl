%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter 1.0.0 — Public API and HTML Utilities
%%%
%%% Backward-compatible with 0.9: start_filter/2, stop_filter/1 and
%%% all HTML utility functions have the same signatures.
%%%
%%% Removed in 1.0.0 (unused by any filter):
%%%   extract_content_blocks/1, aggregate_data/2, classify_content/1,
%%%   extract_images/1, extract_links_with_text/1, extract_text_blocks/1,
%%%   extract_media_content/1, format_content/1 and related types.
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter).

%% Filter lifecycle (unchanged from 0.9)
-export([start_filter/2, stop_filter/1]).

%% HTML utilities (unchanged from 0.9)
-export([
    strip_scripts/1,
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

-define(PAT_DEC,  <<"&#([0-9]+);">>).
-define(PAT_HEX,  <<"&#x([0-9A-Fa-f]+);">>).
-define(PAT_NAM,  <<"&([a-zA-Z]+);">>).
-define(PAT_TAGS, <<"<[^>]*>">>).

%%====================================================================
%% Filter lifecycle
%%====================================================================

-spec start_filter(atom(), module()) -> {ok, pid()} | {error, term()}.
start_filter(FilterName, HandlerModule) ->
    em_filter_sup:start_filter(FilterName, HandlerModule).

-spec stop_filter(atom()) -> ok | {error, term()}.
stop_filter(FilterName) ->
    em_filter_sup:stop_filter(FilterName).

%%====================================================================
%% HTML utilities
%%====================================================================

-spec strip_scripts(binary() | string()) ->
    {ok, binary()} | {error, cleaning_failed}.
strip_scripts(Html) when is_list(Html) ->
    strip_scripts(list_to_binary(Html));
strip_scripts(Html) when is_binary(Html) ->
    try
        {ok, re:replace(Html, "<script[^>]*>.*?</script>", "",
                        [global, dotall, {return, binary}])}
    catch _:R ->
        logger:error("[em_filter] strip_scripts failed: ~p", [R]),
        {error, cleaning_failed}
    end.

-spec extract_elements(binary(), string()) -> term().
extract_elements(Html, Selector) ->
    case Selector of
        "li.b_algo" ->
            re:run(Html,
                "<li[^>]*class=['\"]b_algo['\"][^>]*>(.*?)</li>",
                [global, dotall, {capture, all_but_first, binary}]);
        "div a" ->
            re:run(Html, "<a[^>]*>(.*?)</a>",
                [global, dotall, {capture, all, binary}]);
        "div p" ->
            re:run(Html, "<p[^>]*>(.*?)</p>",
                [global, dotall, {capture, all, binary}]);
        ".algoSlug_icon" ->
            re:run(Html, "class=['\"]algoSlug_icon['\"][^>]*>(.*?)<",
                [global, dotall, {capture, all, binary}]);
        ".news_dt" ->
            re:run(Html, "class=['\"]news_dt['\"][^>]*>(.*?)<",
                [global, dotall, {capture, all, binary}]);
        _ ->
            generic_selector(Html, Selector)
    end.

-spec get_text(binary()) -> binary().
get_text(E) ->
    re:replace(E, ?PAT_TAGS, "", [global, {return, binary}]).

-spec extract_attribute(binary(), string()) -> {ok, binary()} | error.
extract_attribute(E, Attr) ->
    case re:run(E, Attr ++ "=['\"]([^'\"]*)['\"]",
                [{capture, all_but_first, binary}]) of
        {match, [V]} -> {ok, V};
        _            -> error
    end.

-spec clean_text(term(), term(), term()) -> binary().
clean_text(D, I, Dt) ->
    T1 = safe_binary_replace(ensure_binary(D), ensure_binary(I),  <<>>),
    T2 = safe_binary_replace(T1, ensure_binary(Dt), <<>>),
    decode_html_entities(safe_binary_replace(T2, <<" . ">>, <<>>)).

-spec ensure_binary(term()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(_)                   -> <<>>.

-spec safe_binary_replace(binary(), binary(), binary()) -> binary().
safe_binary_replace(S, P, R) ->
    try
        case byte_size(P) of
            0 -> S;
            _ -> binary:replace(S, P, R, [global])
        end
    catch _:_ -> S end.

-spec decode_html_entities(binary()) -> binary().
decode_html_entities(T) ->
    decode_named_entities(decode_hex_entities(decode_numeric_entities(T))).

-spec decode_numeric_entities(binary()) -> binary().
decode_numeric_entities(Text) ->
    case re:run(Text, ?PAT_DEC, [{capture, all, binary}, global]) of
        {match, Ms} ->
            lists:foldl(fun([Full, N], Acc) ->
                try C = unicode:characters_to_binary(
                            [binary_to_integer(N)], unicode, utf8),
                    safe_binary_replace(Acc, Full, C)
                catch _:_ -> Acc end
            end, Text, Ms);
        nomatch -> Text
    end.

-spec decode_hex_entities(binary()) -> binary().
decode_hex_entities(Text) ->
    case re:run(Text, ?PAT_HEX, [{capture, all, binary}, global]) of
        {match, Ms} ->
            lists:foldl(fun([Full, H], Acc) ->
                try C = unicode:characters_to_binary(
                            [binary_to_integer(H, 16)], unicode, utf8),
                    safe_binary_replace(Acc, Full, C)
                catch _:_ -> Acc end
            end, Text, Ms);
        nomatch -> Text
    end.

-spec decode_named_entities(binary()) -> binary().
decode_named_entities(Text) ->
    case re:run(Text, ?PAT_NAM, [{capture, all, binary}, global]) of
        {match, Ms} ->
            lists:foldl(fun([Full, Name], Acc) ->
                case resolve_named_entity(Name) of
                    undefined -> Acc;
                    Char      -> safe_binary_replace(Acc, Full, Char)
                end
            end, Text, Ms);
        nomatch -> Text
    end.

-spec resolve_named_entity(binary()) -> binary() | undefined.
resolve_named_entity(<<"nbsp">>)   -> <<" ">>;
resolve_named_entity(<<"amp">>)    -> <<"&">>;
resolve_named_entity(<<"lt">>)     -> <<"<">>;
resolve_named_entity(<<"gt">>)     -> <<">">>;
resolve_named_entity(<<"quot">>)   -> <<"\"">>;
resolve_named_entity(<<"apos">>)   -> <<"'">>;
resolve_named_entity(<<"eacute">>) -> <<233/utf8>>;
resolve_named_entity(<<"egrave">>) -> <<232/utf8>>;
resolve_named_entity(<<"agrave">>) -> <<224/utf8>>;
resolve_named_entity(<<"ccedil">>) -> <<231/utf8>>;
resolve_named_entity(<<"ocirc">>)  -> <<244/utf8>>;
resolve_named_entity(<<"ecirc">>)  -> <<234/utf8>>;
resolve_named_entity(<<"icirc">>)  -> <<238/utf8>>;
resolve_named_entity(<<"ugrave">>) -> <<249/utf8>>;
resolve_named_entity(<<"aacute">>) -> <<225/utf8>>;
resolve_named_entity(_)            -> undefined.

-spec should_skip_link(binary(), [string()]) -> boolean().
should_skip_link(Link, Excluded) ->
    lists:any(fun(E) ->
        binary:match(Link, list_to_binary(E)) =/= nomatch
    end, Excluded)
    orelse binary:match(Link, <<"http">>) =/= {0, 4}.

%%====================================================================
%% Private helpers
%%====================================================================

generic_selector(Html, Selector) ->
    case parse_sel(Selector) of
        {tag, Tag} ->
            re:run(Html, "<" ++ Tag ++ "[^>]*>(.*?)</" ++ Tag ++ ">",
                   [global, dotall, {capture, all_but_first, binary}]);
        {tag_class, Tag, Class} ->
            re:run(Html, "<" ++ Tag ++ "[^>]*class=['\"][^'\"]*" ++ Class ++
                   "[^'\"]*['\"][^>]*>(.*?)</" ++ Tag ++ ">",
                   [global, dotall, {capture, all_but_first, binary}]);
        {class_only, Class} ->
            re:run(Html, "<[^>]*class=['\"][^'\"]*" ++ Class ++
                   "[^'\"]*['\"][^>]*>(.*?)</[^>]+>",
                   [global, dotall, {capture, all_but_first, binary}]);
        {id, Id} ->
            re:run(Html, "<[^>]*id=['\"]" ++ Id ++ "['\"][^>]*>(.*?)</[^>]+>",
                   [global, dotall, {capture, all_but_first, binary}]);
        {attribute, Attr, Value} ->
            re:run(Html, "<[^>]*" ++ Attr ++ "=['\"]" ++ Value ++
                   "['\"][^>]*>(.*?)</[^>]+>",
                   [global, dotall, {capture, all_but_first, binary}]);
        error -> {match, []}
    end.

parse_sel([$# | Id])    -> {id, Id};
parse_sel([$. | Class]) -> {class_only, Class};
parse_sel([$[ | Rest]) ->
    case string:split(Rest, "=") of
        [Attr, VB] ->
            {attribute, Attr,
             string:trim(string:trim(VB, trailing, "]"), both, "'\"")};
        _ -> error
    end;
parse_sel(Sel) ->
    case string:split(Sel, ".") of
        [Tag, Class] -> {tag_class, Tag, Class};
        [Tag]        -> {tag, Tag};
        _            -> error
    end.
