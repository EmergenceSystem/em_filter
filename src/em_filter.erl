%%%-------------------------------------------------------------------
%%% @doc
%%% `em_filter' - Library for registering Emergence filters with data aggregation
%%%
%%% This module provides functions for:
%%% - Finding an available port for a filter service
%%% - Registering a filter with a discovery service
%%% - Processing HTML content with multiple data types
%%% - Aggregating different content types (text, links, images, etc.)
%%%
%%% @author Steve Roques
%%% @end
%%%-------------------------------------------------------------------
-module(em_filter).

%% Public API
-export([
    start_filter/2,
    stop_filter/1,
    find_port/0,
    register_filter/1,
    get_filter_port/1
]).

%% HTML Utility functions
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

%% Enhanced data aggregation functions
-export([
    extract_content_blocks/1,
    aggregate_data/2,
    classify_content/1,
    extract_images/1,
    extract_links_with_text/1,
    extract_text_blocks/1,
    extract_media_content/1,
    merge_content_types/1,
    format_aggregated_data/1
]).

%% Type specifications
-type port_number() :: 1..65535.
-type filter_url() :: string().
-type content_type() :: text | link | image | video | audio | mixed.
-type content_block() :: #{
    type => content_type(),
    data => term(),
    metadata => map(),
    position => integer()
}.
-type aggregated_content() :: [content_block()].

-define(PORT_RANGE_MIN, 8081).
-define(PORT_RANGE_MAX, 9000).

%%====================================================================
%% API Functions
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Starts a filter service with the given name and handler module.
%%
%% @param FilterName Name of the filter (atom)
%% @param HandlerModule Module to handle requests (module)
%% @return {ok, Pid} if startup is successful, or
%%         {error, Reason} if startup fails
%% @end
%%--------------------------------------------------------------------
-spec start_filter(atom(), module()) -> {ok, pid()} | {error, term()}.
start_filter(FilterName, HandlerModule) ->
    % Start distributed Erlang node
    case net_kernel:start(FilterName, shortnames) of
        {ok, _} ->
            % Find available port
            {ok, Port} = find_port(),
            % Store port number for access by other processes
            persistent_term:put({filter_port, FilterName}, Port),
            
            % Store handler module for reference
            persistent_term:put({handler_module, FilterName}, HandlerModule),
            
            % Start supervisor with filter name
            % Generate the supervisor name but use it directly in the call
            em_filter_sup:start_link(FilterName, HandlerModule, Port)
    end.

%%--------------------------------------------------------------------
%% @doc Stops a running filter service.
%%
%% @param FilterName Name of the filter to stop (atom)
%% @return ok if stopped successfully, or
%%         {error, not_running} if filter is not running
%% @end
%%--------------------------------------------------------------------
-spec stop_filter(atom()) -> ok | {error, not_running}.
stop_filter(FilterName) ->
    SupName = list_to_atom(atom_to_list(FilterName) ++ "_sup"),
    
    case whereis(SupName) of
        undefined ->
            {error, not_running};
        Pid ->
            % Terminate supervisor and all children
            exit(Pid, shutdown),
            
            % Clean up persistent terms
            persistent_term:erase({filter_port, FilterName}),
            persistent_term:erase({handler_module, FilterName}),
            persistent_term:erase({wade_pid, FilterName}),
            
            ok
    end.

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
    find_port_in_range(?PORT_RANGE_MIN, ?PORT_RANGE_MAX).

%%--------------------------------------------------------------------
%% @doc Registers a filter with the discovery service.
%%
%% This function sends an HTTP POST request to the discovery service with
%% the filter information in JSON format.
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
    io:format("Filter URL: ~p~n", [list_to_binary(FilterUrl)]),
    
    FilterUrlBinary = list_to_binary(FilterUrl),
    Body = jsone:encode(#{
        url => FilterUrlBinary,
        name => <<"Emergence Filter Enhanced">>,
        description => <<"Library with enhanced data aggregation capabilities.">>
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
%% @doc Gets the port number for a running filter.
%%
%% @param FilterName Name of the filter
%% @return {ok, Port} if filter is running, or
%%         {error, not_found} if filter is not running
%% @end
%%--------------------------------------------------------------------
-spec get_filter_port(atom()) -> {ok, port_number()} | {error, not_found}.
get_filter_port(FilterName) ->
    case persistent_term:get({filter_port, FilterName}, undefined) of
        undefined -> {error, not_found};
        Port -> {ok, Port}
    end.

%%====================================================================
%% Enhanced Data Aggregation Functions
%%====================================================================

%%--------------------------------------------------------------------
%% @doc Extracts and classifies different content blocks from HTML.
%%
%% @param Html HTML content as binary
%% @return {ok, AggregatedContent} or {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec extract_content_blocks(binary()) -> {ok, aggregated_content()} | {error, term()}.
extract_content_blocks(Html) ->
    try
        % Extract different types of content
        TextBlocks = extract_text_blocks(Html),
        Links = extract_links_with_text(Html),
        Images = extract_images(Html),
        MediaContent = extract_media_content(Html),
        
        % Aggregate all content types
        AllContent = TextBlocks ++ Links ++ Images ++ MediaContent,
        
        % Sort by position in document
        SortedContent = lists:sort(fun(#{position := P1}, #{position := P2}) -> P1 =< P2 end, AllContent),
        
        {ok, SortedContent}
    catch
        _:Reason ->
            {error, {extraction_failed, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc Aggregates data based on specified options.
%%
%% @param Html HTML content
%% @param Options Aggregation options map
%% @return Aggregated content
%% @end
%%--------------------------------------------------------------------
-spec aggregate_data(binary(), map()) -> aggregated_content().
aggregate_data(Html, Options) ->
    IncludeText = maps:get(include_text, Options, true),
    IncludeLinks = maps:get(include_links, Options, true),
    IncludeImages = maps:get(include_images, Options, true),
    IncludeMedia = maps:get(include_media, Options, false),
    MaxItems = maps:get(max_items, Options, 100),
    MinTextLength = maps:get(min_text_length, Options, 10),
    
    {ok, AllContent} = extract_content_blocks(Html),
    
    % Filter based on options
    FilteredContent = lists:filter(fun(#{type := Type, data := Data}) ->
        case Type of
            text when IncludeText ->
                TextContent = maps:get(content, Data, <<>>),
                byte_size(TextContent) >= MinTextLength;
            link when IncludeLinks -> true;
            image when IncludeImages -> true;
            _ when IncludeMedia -> lists:member(Type, [video, audio]);
            _ -> false
        end
    end, AllContent),
    
    % Limit number of items
    lists:sublist(FilteredContent, MaxItems).

%%--------------------------------------------------------------------
%% @doc Classifies content type based on HTML element.
%%
%% @param Element HTML element as binary
%% @return Content type atom
%% @end
%%--------------------------------------------------------------------
-spec classify_content(binary()) -> content_type().
classify_content(Element) ->
    ElementLower = string:lowercase(Element),
    case re:run(ElementLower, "<(\\w+)", [{capture, all_but_first, binary}]) of
        {match, [Tag]} ->
            case Tag of
                <<"img">> -> image;
                <<"video">> -> video;
                <<"audio">> -> audio;
                <<"a">> -> link;
                <<"p">> -> text;
                <<"div">> -> text;
                <<"span">> -> text;
                <<"h1">> -> text;
                <<"h2">> -> text;
                <<"h3">> -> text;
                <<"h4">> -> text;
                <<"h5">> -> text;
                <<"h6">> -> text;
                _ -> mixed
            end;
        _ -> text
    end.

%%--------------------------------------------------------------------
%% @doc Extracts image elements with metadata.
%%
%% @param Html HTML content
%% @return List of image content blocks
%% @end
%%--------------------------------------------------------------------
-spec extract_images(binary()) -> [content_block()].
extract_images(Html) ->
    case re:run(Html, "<img[^>]*>", [global, {capture, all, binary}]) of
        {match, Matches} ->
            lists:foldl(fun([ImgTag], {Acc, Pos}) ->
                case extract_image_data(ImgTag) of
                    {ok, ImageData} ->
                        Block = #{
                            type => image,
                            data => ImageData,
                            metadata => #{
                                tag => ImgTag,
                                extracted_at => erlang:system_time(second)
                            },
                            position => Pos
                        },
                        {[Block | Acc], Pos + 1};
                    error ->
                        {Acc, Pos + 1}
                end
            end, {[], 0}, Matches);
        nomatch ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc Extracts links with associated text.
%%
%% @param Html HTML content
%% @return List of link content blocks
%% @end
%%--------------------------------------------------------------------
-spec extract_links_with_text(binary()) -> [content_block()].
extract_links_with_text(Html) ->
    case re:run(Html, "<a[^>]*href=['\"]([^'\"]*)['\"][^>]*>(.*?)</a>", [global, dotall, {capture, all, binary}]) of
        {match, Matches} ->
            lists:foldl(fun([FullTag, Href, LinkText], {Acc, Pos}) ->
                CleanText = clean_link_text(LinkText),
                case byte_size(CleanText) > 0 of
                    true ->
                        LinkData = #{
                            url => Href,
                            text => CleanText,
                            full_tag => FullTag
                        },
                        Block = #{
                            type => link,
                            data => LinkData,
                            metadata => #{
                                text_length => byte_size(CleanText),
                                extracted_at => erlang:system_time(second)
                            },
                            position => Pos
                        },
                        {[Block | Acc], Pos + 1};
                    false ->
                        {Acc, Pos + 1}
                end
            end, {[], 0}, Matches);
        nomatch ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc Extracts text blocks from various HTML elements.
%%
%% @param Html HTML content
%% @return List of text content blocks
%% @end
%%--------------------------------------------------------------------
-spec extract_text_blocks(binary()) -> [content_block()].
extract_text_blocks(Html) ->
    % Extract from paragraphs, divs, headings, etc.
    TextSelectors = [
        {"<p[^>]*>(.*?)</p>", paragraph},
        {"<div[^>]*>(.*?)</div>", division},
        {"<h[1-6][^>]*>(.*?)</h[1-6]>", heading},
        {"<span[^>]*>(.*?)</span>", span}
    ],
    
    lists:foldl(fun({Pattern, Type}, {Acc, Pos}) ->
        case re:run(Html, Pattern, [global, dotall, {capture, all_but_first, binary}]) of
            {match, Matches} ->
                lists:foldl(fun([TextContent], {InnerAcc, InnerPos}) ->
                    CleanText = decode_html_entities(get_text(TextContent)),
                    case byte_size(CleanText) > 5 of % Minimum text length
                        true ->
                            TextData = #{
                                content => CleanText,
                                element_type => Type,
                                raw_content => TextContent
                            },
                            Block = #{
                                type => text,
                                data => TextData,
                                metadata => #{
                                    length => byte_size(CleanText),
                                    element_type => Type,
                                    extracted_at => erlang:system_time(second)
                                },
                                position => InnerPos
                            },
                            {[Block | InnerAcc], InnerPos + 1};
                        false ->
                            {InnerAcc, InnerPos + 1}
                    end
                end, {Acc, Pos}, Matches);
            nomatch ->
                {Acc, Pos}
        end
    end, {[], 0}, TextSelectors).

%%--------------------------------------------------------------------
%% @doc Extracts media content (video, audio).
%%
%% @param Html HTML content
%% @return List of media content blocks
%% @end
%%--------------------------------------------------------------------
-spec extract_media_content(binary()) -> [content_block()].
extract_media_content(Html) ->
    VideoBlocks = extract_media_by_tag(Html, "video", video),
    AudioBlocks = extract_media_by_tag(Html, "audio", audio),
    VideoBlocks ++ AudioBlocks.

%%--------------------------------------------------------------------
%% @doc Merges different content types into a unified structure.
%%
%% @param ContentBlocks List of content blocks
%% @return Merged content structure
%% @end
%%--------------------------------------------------------------------
-spec merge_content_types([content_block()]) -> map().
merge_content_types(ContentBlocks) ->
    GroupedContent = lists:foldl(fun(#{type := Type} = Block, Acc) ->
        CurrentList = maps:get(Type, Acc, []),
        maps:put(Type, [Block | CurrentList], Acc)
    end, #{}, ContentBlocks),
    
    % Add summary statistics
    Stats = #{
        total_blocks => length(ContentBlocks),
        text_blocks => length(maps:get(text, GroupedContent, [])),
        link_blocks => length(maps:get(link, GroupedContent, [])),
        image_blocks => length(maps:get(image, GroupedContent, [])),
        media_blocks => length(maps:get(video, GroupedContent, [])) + 
                       length(maps:get(audio, GroupedContent, []))
    },
    
    #{
        content => GroupedContent,
        statistics => Stats,
        generated_at => erlang:system_time(second)
    }.

%%--------------------------------------------------------------------
%% @doc Formats aggregated data for output.
%%
%% @param AggregatedData Aggregated content data
%% @return Formatted output map
%% @end
%%--------------------------------------------------------------------
-spec format_aggregated_data(map()) -> map().
format_aggregated_data(#{content := Content, statistics := Stats} = Data) ->
    FormattedContent = maps:map(fun(_Type, Blocks) ->
        lists:map(fun(#{data := BlockData, metadata := Metadata}) ->
            #{
                data => BlockData,
                metadata => Metadata
            }
        end, Blocks)
    end, Content),
    
    #{
        aggregated_content => FormattedContent,
        summary => Stats,
        metadata => #{
            generated_at => maps:get(generated_at, Data),
            version => <<"1.0">>
        }
    }.

%%====================================================================
%% Internal Helper Functions
%%====================================================================

extract_image_data(ImgTag) ->
    case extract_attribute(ImgTag, "src") of
        {ok, Src} ->
            Alt = case extract_attribute(ImgTag, "alt") of
                {ok, AltText} -> AltText;
                error -> <<>>
            end,
            Title = case extract_attribute(ImgTag, "title") of
                {ok, TitleText} -> TitleText;
                error -> <<>>
            end,
            {ok, #{
                src => Src,
                alt => Alt,
                title => Title
            }};
        error ->
            error
    end.

clean_link_text(LinkText) ->
    CleanText = get_text(LinkText),
    decode_html_entities(CleanText).

extract_media_by_tag(Html, Tag, Type) ->
    Pattern = "<" ++ Tag ++ "[^>]*>(.*?)</" ++ Tag ++ ">",
    case re:run(Html, Pattern, [global, dotall, {capture, all, binary}]) of
        {match, Matches} ->
            lists:foldl(fun([FullTag, _Content], {Acc, Pos}) ->
                case extract_media_attributes(FullTag) of
                    {ok, MediaData} ->
                        Block = #{
                            type => Type,
                            data => MediaData,
                            metadata => #{
                                tag => Tag,
                                extracted_at => erlang:system_time(second)
                            },
                            position => Pos
                        },
                        {[Block | Acc], Pos + 1};
                    error ->
                        {Acc, Pos + 1}
                end
            end, {[], 0}, Matches);
        nomatch ->
            []
    end.

extract_media_attributes(MediaTag) ->
    Src = case extract_attribute(MediaTag, "src") of
        {ok, SrcValue} -> SrcValue;
        error -> <<>>
    end,
    Controls = case extract_attribute(MediaTag, "controls") of
        {ok, _} -> true;
        error -> false
    end,
    case byte_size(Src) > 0 of
        true ->
            {ok, #{
                src => Src,
                controls => Controls
            }};
        false ->
            error
    end.

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
            parse_generic_selector(Html, Selector)
    end.

parse_generic_selector(Html, Selector) ->
    case parse_selector(Selector) of
        {tag, Tag} ->
            Pattern = "<" ++ Tag ++ "[^>]*>(.*?)</" ++ Tag ++ ">",
            re:run(Html, Pattern, [global, dotall, {capture, all_but_first, binary}]);
        
        {tag_class, Tag, Class} ->
            Pattern = "<" ++ Tag ++ "[^>]*class=['\"][^'\"]*" ++ Class ++ "[^'\"]*['\"][^>]*>(.*?)</" ++ Tag ++ ">",
            re:run(Html, Pattern, [global, dotall, {capture, all_but_first, binary}]);
        
        {class_only, Class} ->
            Pattern = "<[^>]*class=['\"][^'\"]*" ++ Class ++ "[^'\"]*['\"][^>]*>(.*?)</[^>]+>",
            re:run(Html, Pattern, [global, dotall, {capture, all_but_first, binary}]);
        
        {id, Id} ->
            Pattern = "<[^>]*id=['\"]" ++ Id ++ "['\"][^>]*>(.*?)</[^>]+>",
            re:run(Html, Pattern, [global, dotall, {capture, all_but_first, binary}]);
        
        {attribute, Attr, Value} ->
            Pattern = "<[^>]*" ++ Attr ++ "=['\"]" ++ Value ++ "['\"][^>]*>(.*?)</[^>]+>",
            re:run(Html, Pattern, [global, dotall, {capture, all_but_first, binary}]);
        
        error ->
            {match, []}
    end.

parse_selector(Selector) ->
    case Selector of
        [$# | Id] ->
            {id, Id};
        
        [$. | Class] ->
            {class_only, Class};
        
        [$[ | Rest] ->
            case string:split(Rest, "=") of
                [Attr, ValueWithBracket] ->
                    Value = string:trim(ValueWithBracket, trailing, "]"),
                    CleanValue = string:trim(Value, both, "'\""),
                    {attribute, Attr, CleanValue};
                _ -> error
            end;
        
        _ ->
            case string:split(Selector, ".") of
                [Tag, Class] ->
                    {tag_class, Tag, Class};
                [Tag] ->
                    {tag, Tag};
                _ -> error
            end
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

