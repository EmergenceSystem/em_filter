-module(html_parser).
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

