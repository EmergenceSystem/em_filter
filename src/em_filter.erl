%%%-------------------------------------------------------------------
%%% @doc
%%% em_filter — Public API and HTML Utilities
%%%
%%% This module is the main entry point for the `em_filter' library.
%%% It exposes two categories of functionality:
%%%
%%% <ul>
%%%   <li><b>Filter lifecycle</b> — start and stop named filter
%%%       processes that connect to an `em_disco' discovery
%%%       service.</li>
%%%   <li><b>HTML utilities</b> — a collection of helpers for
%%%       parsing, cleaning, and extracting structured content
%%%       from raw HTML binaries.</li>
%%% </ul>
%%%
%%% === Implementing a filter ===
%%%
%%% A filter is a module that exports a single callback:
%%%
%%% ```
%%% -module(my_filter).
%%% -export([handle/1]).
%%%
%%% handle(Body) ->
%%%     %% Body is the raw query binary forwarded by em_disco.
%%%     %% Return any JSON-encodable term.
%%%     process(Body).
%%% '''
%%%
%%% Start the filter with:
%%%
%%% ```
%%% em_filter:start_filter(my_filter, my_filter).
%%% '''
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter).

%% Filter lifecycle
-export([start_filter/2, stop_filter/1]).

%% HTML utilities
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

%% Content extraction
-export([
    extract_content_blocks/1,
    aggregate_data/2,
    classify_content/1,
    extract_images/1,
    extract_links_with_text/1,
    extract_text_blocks/1,
    extract_media_content/1,
    format_content/1
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type content_type() :: text | link | image | video | audio | mixed.
%% The semantic category of an extracted content block.

-type content_block() :: #{
    type     => content_type(),
    data     => term(),
    metadata => map(),
    position => integer()
}.
%% A single unit of structured content extracted from an HTML document.
%%
%% Fields:
%% <ul>
%%%   <li>`type'     — semantic category of the content.</li>
%%%   <li>`data'     — type-specific payload map.</li>
%%%   <li>`metadata' — extra information (lengths, tags, timestamps).</li>
%%%   <li>`position' — extraction order index, used for sorting.</li>
%%% </ul>

-type aggregated_content() :: [content_block()].
%% An ordered list of content blocks extracted from a single HTML document.

-export_type([content_type/0, content_block/0, aggregated_content/0]).

%% Pre-compiled regex patterns — defined as macros so they are
%% inlined as literals and compiled at the re:run/3 call site.
-define(PAT_DEC,  <<"&#([0-9]+);">>).
-define(PAT_HEX,  <<"&#x([0-9A-Fa-f]+);">>).
-define(PAT_NAM,  <<"&([a-zA-Z]+);">>).
-define(PAT_TAGS, <<"<[^>]*>">>).

%%====================================================================
%% Filter lifecycle
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts a named filter and connects it to the discovery service.
%%
%% Internally delegates to `em_filter_sup:start_filter/2', which
%% starts an `em_filter_server' child under the library supervisor.
%% The server opens a persistent WebSocket connection to `em_disco'
%% and registers `FilterName' so that incoming queries are routed to
%% `HandlerModule:handle/1'.
%%
%% If a filter with the same name is already running, the existing
%% pid is returned without starting a duplicate.
%%
%% @param FilterName    Unique atom identifying this filter instance.
%% @param HandlerModule Module exporting `handle/1' that processes
%%                      queries.
%% @return `{ok, Pid}' on success, `{error, Reason}' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec start_filter(atom(), module()) -> {ok, pid()} | {error, term()}.
start_filter(FilterName, HandlerModule) ->
    em_filter_sup:start_filter(FilterName, HandlerModule).

%%--------------------------------------------------------------------
%% @doc Stops a running filter and closes its connection to em_disco.
%%
%% Terminates the `em_filter_server' process associated with
%% `FilterName'. The filter is automatically deregistered from the
%% discovery service upon disconnection.
%%
%% @param FilterName Atom used when starting the filter.
%% @return `ok' on success, `{error, not_running}' if the filter is
%%         not currently active.
%% @end
%%--------------------------------------------------------------------
-spec stop_filter(atom()) -> ok | {error, term()}.
stop_filter(FilterName) ->
    em_filter_sup:stop_filter(FilterName).

%%====================================================================
%% Content extraction
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Extracts all content blocks from an HTML document.
%%
%% Runs all extractors (text, links, images, media) over the given
%% HTML binary and merges the results into a single list sorted by
%% their original position in the document.
%%
%% @param Html Raw HTML binary.
%% @return `{ok, Blocks}' with blocks in document order, or
%%         `{error, {extraction_failed, Reason}}' on failure.
%% @end
%%--------------------------------------------------------------------
-spec extract_content_blocks(binary()) ->
    {ok, aggregated_content()} | {error, term()}.
extract_content_blocks(Html) ->
    try
        All = extract_text_blocks(Html) ++
              extract_links_with_text(Html) ++
              extract_images(Html) ++
              extract_media_content(Html),
        Sorted = lists:sort(
            fun(#{position := A}, #{position := B}) -> A =< B end, All),
        {ok, Sorted}
    catch
        _:Reason -> {error, {extraction_failed, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc Extracts and filters content blocks according to options.
%%
%% Calls `extract_content_blocks/1' and then applies the filters
%% described in `Options'. The following keys are supported:
%%
%% <ul>
%%%   <li>`include_text'    (default `true')  — include text blocks.</li>
%%%   <li>`include_links'   (default `true')  — include anchor tags.</li>
%%%   <li>`include_images'  (default `true')  — include `<img>' tags.</li>
%%%   <li>`include_media'   (default `false') — include video/audio.</li>
%%%   <li>`max_items'       (default `100')   — cap on total blocks.</li>
%%%   <li>`min_text_length' (default `10')    — minimum byte length
%%%        for text blocks to be kept.</li>
%%% </ul>
%%%
%%% @param Html    Raw HTML binary.
%%% @param Options Map of extraction options (see above).
%%% @return Filtered and capped list of content blocks, or
%%%         `{error, Reason}' if extraction fails.
%% @end
%%--------------------------------------------------------------------
-spec aggregate_data(binary(), map()) ->
    aggregated_content() | {error, term()}.
aggregate_data(Html, Options) ->
    IncludeText   = maps:get(include_text,    Options, true),
    IncludeLinks  = maps:get(include_links,   Options, true),
    IncludeImages = maps:get(include_images,  Options, true),
    IncludeMedia  = maps:get(include_media,   Options, false),
    MaxItems      = maps:get(max_items,       Options, 100),
    MinTextLen    = maps:get(min_text_length, Options, 10),
    case extract_content_blocks(Html) of
        {ok, All} ->
            Filtered = lists:filter(fun(#{type := Type, data := Data}) ->
                case Type of
                    text  when IncludeText   ->
                        byte_size(maps:get(content, Data, <<>>)) >= MinTextLen;
                    link  when IncludeLinks  -> true;
                    image when IncludeImages -> true;
                    _     when IncludeMedia  ->
                        lists:member(Type, [video, audio]);
                    _ -> false
                end
            end, All),
            lists:sublist(Filtered, MaxItems);
        {error, _} = Err -> Err
    end.

%%--------------------------------------------------------------------
%% @doc Infers the content type of a raw HTML element binary.
%%
%% Matches the opening tag name against a fixed set of known elements.
%% Returns `mixed' for any tag not explicitly recognised.
%%
%% @param Element Raw binary containing at least one HTML tag.
%% @return The inferred `content_type()'.
%% @end
%%--------------------------------------------------------------------
-spec classify_content(binary()) -> content_type().
classify_content(Element) ->
    Lower = string:lowercase(Element),
    case re:run(Lower, "<(\\w+)", [{capture, all_but_first, binary}]) of
        {match, [Tag]} ->
            case Tag of
                <<"img">>   -> image;
                <<"video">> -> video;
                <<"audio">> -> audio;
                <<"a">>     -> link;
                <<"p">>     -> text;
                <<"div">>   -> text;
                <<"span">>  -> text;
                <<"h1">>    -> text; <<"h2">> -> text; <<"h3">> -> text;
                <<"h4">>    -> text; <<"h5">> -> text; <<"h6">> -> text;
                _           -> mixed
            end;
        _ -> text
    end.

%%--------------------------------------------------------------------
%% @doc Extracts all `<img>' tags from an HTML binary.
%%
%% Each match is turned into a `content_block()' of type `image'.
%% The block data map contains:
%% <ul>
%%%   <li>`src'   — value of the `src' attribute (required).</li>
%%%   <li>`alt'   — value of the `alt' attribute, or `<<>>'.</li>
%%%   <li>`title' — value of the `title' attribute, or `<<>>'.</li>
%%% </ul>
%%% Images whose `src' attribute is absent are silently skipped.
%%%
%%% @param Html Raw HTML binary.
%%% @return List of image content blocks in document order.
%% @end
%%--------------------------------------------------------------------
-spec extract_images(binary()) -> [content_block()].
extract_images(Html) ->
    case re:run(Html, "<img[^>]*>", [global, {capture, all, binary}]) of
        {match, Matches} ->
            {Blocks, _} = lists:foldl(fun([Tag], {Acc, Pos}) ->
                case img_data(Tag) of
                    {ok, Data} ->
                        {[block(image, Data, #{tag => Tag}, Pos) | Acc],
                         Pos + 1};
                    error -> {Acc, Pos + 1}
                end
            end, {[], 0}, Matches),
            lists:reverse(Blocks);
        nomatch -> []
    end.

%%--------------------------------------------------------------------
%% @doc Extracts all `<a href="…">…</a>' links from an HTML binary.
%%
%% Each match is turned into a `content_block()' of type `link'.
%% The block data map contains:
%% <ul>
%%%   <li>`url'      — value of the `href' attribute.</li>
%%%   <li>`text'     — visible link text, stripped of tags and with
%%%                    HTML entities decoded.</li>
%%%   <li>`full_tag' — the complete raw anchor tag binary.</li>
%%% </ul>
%%% Links whose visible text is empty after stripping are skipped.
%%%
%%% @param Html Raw HTML binary.
%%% @return List of link content blocks in document order.
%% @end
%%--------------------------------------------------------------------
-spec extract_links_with_text(binary()) -> [content_block()].
extract_links_with_text(Html) ->
    Pat = "<a[^>]*href=['\"]([^'\"]*)['\"][^>]*>(.*?)</a>",
    case re:run(Html, Pat, [global, dotall, {capture, all, binary}]) of
        {match, Matches} ->
            {Blocks, _} = lists:foldl(
                fun([Full, Href, Raw], {Acc, Pos}) ->
                    Text = decode_html_entities(get_text(Raw)),
                    case byte_size(Text) > 0 of
                        true ->
                            Data = #{url => Href, text => Text,
                                     full_tag => Full},
                            Meta = #{text_length => byte_size(Text)},
                            {[block(link, Data, Meta, Pos) | Acc], Pos + 1};
                        false -> {Acc, Pos + 1}
                    end
                end, {[], 0}, Matches),
            lists:reverse(Blocks);
        nomatch -> []
    end.

%%--------------------------------------------------------------------
%% @doc Extracts text content from block-level HTML elements.
%%
%% Scans for `<p>', `<div>', `<h1>'–`<h6>', and `<span>' elements,
%% strips inner tags, decodes HTML entities, and discards any result
%% shorter than 5 bytes.
%%
%% Each block data map contains:
%% <ul>
%%%   <li>`content'      — clean UTF-8 text.</li>
%%%   <li>`element_type' — atom: `paragraph', `division', `heading',
%%%                        or `span'.</li>
%%%   <li>`raw_content'  — original inner HTML before cleaning.</li>
%%% </ul>
%%%
%%% @param Html Raw HTML binary.
%%% @return List of text content blocks in document order.
%% @end
%%--------------------------------------------------------------------
-spec extract_text_blocks(binary()) -> [content_block()].
extract_text_blocks(Html) ->
    Selectors = [
        {"<p[^>]*>(.*?)</p>",           paragraph},
        {"<div[^>]*>(.*?)</div>",        division},
        {"<h[1-6][^>]*>(.*?)</h[1-6]>", heading},
        {"<span[^>]*>(.*?)</span>",      span}
    ],
    {Blocks, _} = lists:foldl(fun({Pattern, ElemType}, {Acc, Pos}) ->
        case re:run(Html, Pattern,
                    [global, dotall, {capture, all_but_first, binary}]) of
            {match, Matches} ->
                lists:foldl(fun([Raw], {A, P}) ->
                    Clean = decode_html_entities(get_text(Raw)),
                    case byte_size(Clean) > 5 of
                        true ->
                            Data = #{content      => Clean,
                                     element_type => ElemType,
                                     raw_content  => Raw},
                            Meta = #{length       => byte_size(Clean),
                                     element_type => ElemType},
                            {[block(text, Data, Meta, P) | A], P + 1};
                        false -> {A, P + 1}
                    end
                end, {Acc, Pos}, Matches);
            nomatch -> {Acc, Pos}
        end
    end, {[], 0}, Selectors),
    lists:reverse(Blocks).

%%--------------------------------------------------------------------
%% @doc Extracts `<video>' and `<audio>' elements from an HTML binary.
%%
%% Each match is turned into a `content_block()' of type `video' or
%% `audio'. The block data map contains:
%% <ul>
%%%   <li>`src'      — value of the `src' attribute.</li>
%%%   <li>`controls' — `true' if the `controls' attribute is present,
%%%                    `false' otherwise.</li>
%%% </ul>
%%% Elements without a `src' attribute are skipped.
%%%
%%% @param Html Raw HTML binary.
%%% @return List of media content blocks in document order.
%% @end
%%--------------------------------------------------------------------
-spec extract_media_content(binary()) -> [content_block()].
extract_media_content(Html) ->
    media_by_tag(Html, "video", video) ++
    media_by_tag(Html, "audio", audio).

%%--------------------------------------------------------------------
%% @doc Groups a flat list of content blocks by type and summarises them.
%%
%% Returns a map with the following top-level keys:
%% <ul>
%%%   <li>`content'      — map from `content_type()' to a list of
%%%                        `#{data, metadata}' maps.</li>
%%%   <li>`summary'      — aggregate counts per type.</li>
%%%   <li>`generated_at' — Unix timestamp (seconds) of the call.</li>
%%% </ul>
%%%
%%% @param Blocks List of content blocks, typically from
%%%               `extract_content_blocks/1'.
%%% @return Formatted summary map.
%% @end
%%--------------------------------------------------------------------
-spec format_content([content_block()]) -> map().
format_content(Blocks) ->
    Grouped = lists:foldl(fun(#{type := T} = B, Acc) ->
        maps:put(T, [B | maps:get(T, Acc, [])], Acc)
    end, #{}, Blocks),
    Formatted = maps:map(fun(_T, Bs) ->
        [#{data => D, metadata => M} || #{data := D, metadata := M} <- Bs]
    end, Grouped),
    #{
        content    => Formatted,
        summary    => #{
            total_blocks => length(Blocks),
            text_blocks  => length(maps:get(text,  Grouped, [])),
            link_blocks  => length(maps:get(link,  Grouped, [])),
            image_blocks => length(maps:get(image, Grouped, [])),
            media_blocks => length(maps:get(video, Grouped, [])) +
                            length(maps:get(audio, Grouped, []))
        },
        generated_at => ts()
    }.

%%====================================================================
%% HTML utilities
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Removes all `<script>…</script>' blocks from an HTML binary.
%%
%% Accepts both `binary()' and `string()' input; strings are converted
%% to binary before processing. The replacement is applied globally,
%% including across line boundaries.
%%
%% @param Html Raw HTML as a binary or a character list.
%% @return `{ok, Cleaned}' with script tags removed, or
%%         `{error, cleaning_failed}' if the regex operation raises.
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc Extracts HTML elements matching a CSS-like selector string.
%%
%% Supported selector forms:
%% <ul>
%%%   <li>`"tag"'          — matches `<tag>…</tag>'.</li>
%%%   <li>`"tag.class"'    — matches a tag with a specific class.</li>
%%%   <li>`".class"'       — matches any element with the class.</li>
%%%   <li>`"#id"'          — matches any element with the id.</li>
%%%   <li>`"[attr=value]"' — matches by attribute value.</li>
%%% </ul>
%%% A small set of Bing-specific selectors (`"li.b_algo"',
%%% `"div a"', etc.) are also handled explicitly for performance.
%%%
%%% The return value mirrors `re:run/3' with
%%% `{capture, all_but_first, binary}'.
%%%
%%% @param Html     Raw HTML binary.
%%% @param Selector CSS-like selector string.
%%% @return `re:run/3' result (`{match, Captures}' or `nomatch').
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc Strips all HTML tags from a binary, returning plain text.
%%
%% Uses a greedy `<[^>]*>' pattern to remove every tag. The result
%% is returned as a binary.
%%
%% @param Element Binary that may contain HTML tags.
%% @return Plain-text binary with all tags removed.
%% @end
%%--------------------------------------------------------------------
-spec get_text(binary()) -> binary().
get_text(E) ->
    re:replace(E, ?PAT_TAGS, "", [global, {return, binary}]).

%%--------------------------------------------------------------------
%% @doc Extracts the value of a named HTML attribute from a tag binary.
%%
%% Supports both single-quoted and double-quoted attribute values.
%%
%% Example:
%% ```
%% {ok, <<"https://example.com">>} =
%%     em_filter:extract_attribute(<<"<a href=\"https://example.com\">">>, "href").
%% '''
%%
%% @param Element Binary containing an HTML opening tag.
%% @param Attr    Attribute name as a string.
%% @return `{ok, Value}' if the attribute is present, `error' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec extract_attribute(binary(), string()) -> {ok, binary()} | error.
extract_attribute(E, Attr) ->
    case re:run(E, Attr ++ "=['\"]([^'\"]*)['\"]",
                [{capture, all_but_first, binary}]) of
        {match, [V]} -> {ok, V};
        _            -> error
    end.

%%--------------------------------------------------------------------
%% @doc Builds a clean text binary by removing substrings and decoding entities.
%%
%% Removes occurrences of `I' and `Dt' from `D', then removes any
%% remaining `" . "' separators, and finally decodes all HTML entities
%% in the result.
%%
%% This helper is typically used to clean scraped page titles or
%% descriptions that embed site-name suffixes.
%%
%% @param D  Base text as a binary (or any term coerced by `ensure_binary/1').
%% @param I  First substring to remove.
%% @param Dt Second substring to remove.
%% @return Cleaned UTF-8 binary.
%% @end
%%--------------------------------------------------------------------
-spec clean_text(term(), term(), term()) -> binary().
clean_text(D, I, Dt) ->
    T1 = safe_binary_replace(ensure_binary(D), ensure_binary(I),  <<>>),
    T2 = safe_binary_replace(T1, ensure_binary(Dt), <<>>),
    decode_html_entities(safe_binary_replace(T2, <<" . ">>, <<>>)).

%%--------------------------------------------------------------------
%% @doc Coerces a value to a binary, returning `<<>>' for non-binaries.
%%
%% @param Term Any Erlang term.
%% @return The original binary if `Term' is already a `binary()',
%%         `<<>>' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec ensure_binary(term()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(_)                   -> <<>>.

%%--------------------------------------------------------------------
%% @doc Replaces all occurrences of `Pattern' in `Subject' with `Replacement'.
%%
%% Wraps `binary:replace/4' in a try-catch so that a zero-length
%% pattern or any other error leaves `Subject' unchanged rather than
%% raising.
%%
%% @param Subject     Binary to search in.
%% @param Pattern     Binary to search for; a zero-length binary is a no-op.
%% @param Replacement Binary to substitute for each occurrence.
%% @return Modified binary, or the original `Subject' on error.
%% @end
%%--------------------------------------------------------------------
-spec safe_binary_replace(binary(), binary(), binary()) -> binary().
safe_binary_replace(S, P, R) ->
    try
        case byte_size(P) of
            0 -> S;
            _ -> binary:replace(S, P, R, [global])
        end
    catch _:_ -> S end.

%%--------------------------------------------------------------------
%% @doc Decodes all HTML character references and named entities in a binary.
%%
%% Applies the three decoding passes in order:
%% <ol>
%%%   <li>Decimal numeric entities  (`&#NNN;')</li>
%%%   <li>Hexadecimal numeric entities (`&#xHH;')</li>
%%%   <li>Named entities (`&name;')</li>
%%% </ol>
%%%
%%% @param Text Binary that may contain HTML entity references.
%%% @return Binary with all recognised entities replaced by their
%%%         UTF-8 equivalents.
%% @end
%%--------------------------------------------------------------------
-spec decode_html_entities(binary()) -> binary().
decode_html_entities(T) ->
    decode_named_entities(decode_hex_entities(decode_numeric_entities(T))).

%%--------------------------------------------------------------------
%% @doc Decodes decimal numeric HTML entities (`&#NNN;') in a binary.
%%
%% Each matched entity is converted to its Unicode code point and
%% encoded as UTF-8. Entities whose code point cannot be encoded are
%% left unchanged.
%%
%% @param Text Binary that may contain decimal entities.
%% @return Binary with decimal entities replaced by UTF-8 characters.
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc Decodes hexadecimal numeric HTML entities (`&#xHH;') in a binary.
%%
%% Each matched entity is converted to its Unicode code point and
%% encoded as UTF-8. Entities whose code point cannot be encoded are
%% left unchanged.
%%
%% @param Text Binary that may contain hexadecimal entities.
%% @return Binary with hex entities replaced by UTF-8 characters.
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc Decodes named HTML entities (`&name;') in a binary.
%%
%% Only entities recognised by `resolve_named_entity/1' are replaced;
%% unknown entity names are left unchanged.
%%
%% @param Text Binary that may contain named entities.
%% @return Binary with recognised named entities replaced by their
%%         UTF-8 equivalents.
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc Maps a named HTML entity to its UTF-8 binary representation.
%%
%% Returns `undefined' for any entity name not in the built-in table.
%% The current table covers the most common entities:
%% `nbsp', `amp', `lt', `gt', `quot', `apos', and a selection of
%% accented Latin characters used in French.
%%
%% @param Name Entity name binary without surrounding `&' and `;'.
%% @return The corresponding UTF-8 binary, or `undefined'.
%% @end
%%--------------------------------------------------------------------
-spec resolve_named_entity(binary()) -> binary() | undefined.
resolve_named_entity(<<"nbsp">>)   -> <<" ">>;
resolve_named_entity(<<"amp">>)    -> <<"&">>;
resolve_named_entity(<<"lt">>)     -> <<"<">>;
resolve_named_entity(<<"gt">>)     -> <<">">>;
resolve_named_entity(<<"quot">>)   -> <<"\"">>;
resolve_named_entity(<<"apos">>)   -> <<"'">>;
resolve_named_entity(<<"eacute">>) -> <<"é"/utf8>>;
resolve_named_entity(<<"egrave">>) -> <<"è"/utf8>>;
resolve_named_entity(<<"agrave">>) -> <<"à"/utf8>>;
resolve_named_entity(<<"ccedil">>) -> <<"ç"/utf8>>;
resolve_named_entity(_)            -> undefined.

%%--------------------------------------------------------------------
%% @doc Returns `true' if a link URL should be skipped.
%%
%% A link is considered skippable when either:
%% <ul>
%%%   <li>It contains one of the substrings listed in `Excluded', or</li>
%%%   <li>It does not begin with `"http"' (i.e. it is relative,
%%%       an anchor, a `mailto:', etc.).</li>
%%% </ul>
%%%
%%% @param Link     Absolute or relative URL binary to test.
%%% @param Excluded List of substring strings that mark a link as excluded.
%%% @return `true' if the link should be ignored, `false' otherwise.
%% @end
%%--------------------------------------------------------------------
-spec should_skip_link(binary(), [string()]) -> boolean().
should_skip_link(Link, Excluded) ->
    lists:any(fun(E) ->
        binary:match(Link, list_to_binary(E)) =/= nomatch
    end, Excluded)
    orelse binary:match(Link, <<"http">>) =/= {0, 4}.

%%====================================================================
%% Private helpers
%%====================================================================

%% Returns the current Unix timestamp in seconds.
ts() -> erlang:system_time(second).

%% Constructs a content_block() map from its components.
block(Type, Data, Meta, Pos) ->
    #{type     => Type,
      data     => Data,
      metadata => Meta#{extracted_at => ts()},
      position => Pos}.

%% Builds the data map for an image block, failing if src is absent.
img_data(Tag) ->
    case extract_attribute(Tag, "src") of
        {ok, Src} ->
            {ok, #{src   => Src,
                   alt   => attr_or(Tag, "alt"),
                   title => attr_or(Tag, "title")}};
        error -> error
    end.

%% Extracts an attribute value or returns <<>> when absent.
attr_or(Tag, A) ->
    case extract_attribute(Tag, A) of {ok, V} -> V; _ -> <<>> end.

%% Extracts media elements of a given HTML tag name as content blocks.
media_by_tag(Html, Tag, Type) ->
    Pattern = "<" ++ Tag ++ "[^>]*>(.*?)</" ++ Tag ++ ">",
    case re:run(Html, Pattern, [global, dotall, {capture, all, binary}]) of
        {match, Matches} ->
            {Blocks, _} = lists:foldl(fun([Full | _], {Acc, Pos}) ->
                Src = attr_or(Full, "src"),
                Controls = case extract_attribute(Full, "controls") of
                               {ok, _} -> true; _ -> false end,
                case byte_size(Src) > 0 of
                    true ->
                        Data = #{src => Src, controls => Controls},
                        Meta = #{tag => list_to_binary(Tag)},
                        {[block(Type, Data, Meta, Pos) | Acc], Pos + 1};
                    false -> {Acc, Pos + 1}
                end
            end, {[], 0}, Matches),
            lists:reverse(Blocks);
        nomatch -> []
    end.

%% Dispatches a generic CSS selector to the appropriate regex strategy.
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

%% Parses a CSS selector string into a tagged tuple for generic_selector/2.
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
