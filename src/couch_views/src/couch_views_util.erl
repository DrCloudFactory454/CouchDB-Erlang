% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_views_util).

-export([
    ddoc_to_mrst/2,
    collate_fun/1,
    validate_args/1,
    validate_args/2,
    is_paginated/1,
    active_tasks_info/5,
    set_view_type/3,
    set_extra/3,
    get_view_queries/1,
    get_view_keys/1,
    extract_view/4
]).

-include_lib("couch/include/couch_db.hrl").
-include("couch_views.hrl").
-include_lib("kernel/include/logger.hrl").

ddoc_to_mrst(DbName, #doc{id = Id, body = {Fields}}) ->
    MakeDict = fun
        ({Name, {MRFuns}}, DictBySrcAcc) ->
            case couch_util:get_value(<<"map">>, MRFuns) of
                MapSrc when MapSrc /= undefined ->
                    RedSrc = couch_util:get_value(<<"reduce">>, MRFuns, null),
                    {ViewOpts} = couch_util:get_value(<<"options">>, MRFuns, {[]}),
                    View =
                        case dict:find({MapSrc, ViewOpts}, DictBySrcAcc) of
                            {ok, View0} -> View0;
                            error -> #mrview{def = MapSrc, options = ViewOpts}
                        end,
                    {MapNames, RedSrcs} =
                        case RedSrc of
                            null ->
                                MNames = [Name | View#mrview.map_names],
                                {MNames, View#mrview.reduce_funs};
                            _ ->
                                RedFuns = [{Name, RedSrc} | View#mrview.reduce_funs],
                                {View#mrview.map_names, RedFuns}
                        end,
                    View2 = View#mrview{map_names = MapNames, reduce_funs = RedSrcs},
                    dict:store({MapSrc, ViewOpts}, View2, DictBySrcAcc);
                undefined ->
                    DictBySrcAcc
            end;
        ({Name, Else}, DictBySrcAcc) ->
            ?LOG_ERROR(#{
                what => invalid_view_definition,
                db => DbName,
                ddoc => Id,
                view => Name
            }),
            couch_log:error(
                "design_doc_to_view_group ~s views ~p",
                [Name, Else]
            ),
            DictBySrcAcc
    end,
    {DesignOpts} = proplists:get_value(<<"options">>, Fields, {[]}),
    Partitioned = proplists:get_value(<<"partitioned">>, DesignOpts, false),

    {RawViews} = couch_util:get_value(<<"views">>, Fields, {[]}),
    BySrc = lists:foldl(MakeDict, dict:new(), RawViews),

    NumViews = fun({_, View}, N) ->
        {View#mrview{id_num = N}, N + 1}
    end,
    {Views0, _} = lists:mapfoldl(NumViews, 0, lists:sort(dict:to_list(BySrc))),
    Views1 = maybe_disable_custom_reduce_funs(Views0),

    Language = couch_util:get_value(<<"language">>, Fields, <<"javascript">>),
    Lib = couch_util:get_value(<<"lib">>, RawViews, {[]}),

    IdxState = #mrst{
        db_name = DbName,
        idx_name = Id,
        lib = Lib,
        views = Views1,
        language = Language,
        design_opts = DesignOpts,
        partitioned = Partitioned
    },
    SigInfo = {Views1, Language, DesignOpts, sort_lib(Lib)},
    {ok, IdxState#mrst{sig = couch_hash:md5_hash(term_to_binary(SigInfo))}}.

set_view_type(_Args, _ViewName, []) ->
    throw({not_found, missing_named_view});
set_view_type(Args, ViewName, [View | Rest]) ->
    RedNames = [N || {N, _} <- View#mrview.reduce_funs],
    case lists:member(ViewName, RedNames) of
        true ->
            case Args#mrargs.reduce of
                false -> Args#mrargs{view_type = map};
                _ -> Args#mrargs{view_type = red}
            end;
        false ->
            case lists:member(ViewName, View#mrview.map_names) of
                true -> Args#mrargs{view_type = map};
                false -> set_view_type(Args, ViewName, Rest)
            end
    end.

set_extra(#mrargs{} = Args, Key, Value) ->
    Extra0 = Args#mrargs.extra,
    Extra1 = lists:ukeysort(1, [{Key, Value} | Extra0]),
    Args#mrargs{extra = Extra1}.

extract_view(_Lang, _Args, _ViewName, []) ->
    throw({not_found, missing_named_view});
extract_view(Lang, #mrargs{view_type = map} = Args, Name, [View | Rest]) ->
    Names = View#mrview.map_names ++ [N || {N, _} <- View#mrview.reduce_funs],
    case lists:member(Name, Names) of
        true -> {map, View, Args};
        _ -> extract_view(Lang, Args, Name, Rest)
    end;
extract_view(Lang, #mrargs{view_type = red} = Args, Name, [View | Rest]) ->
    RedNames = [N || {N, _} <- View#mrview.reduce_funs],
    case lists:member(Name, RedNames) of
        true -> {red, {index_of(Name, RedNames), Lang, View}, Args};
        false -> extract_view(Lang, Args, Name, Rest)
    end.

collate_fun(View) ->
    #mrview{
        options = Options
    } = View,
    case couch_util:get_value(<<"collation">>, Options) of
        <<"raw">> -> fun collate_raw/2;
        _ -> fun collate_rows/2
    end.

collate_raw(A, A) -> eq;
collate_raw(A, B) when A < B -> lt;
collate_raw(A, B) when A > B -> gt.

collate_rows({KeyA, DocIdA}, {KeyB, DocIdB}) ->
    case couch_ejson_compare:less(KeyA, KeyB) of
        N when N < 0 -> lt;
        0 when DocIdA < DocIdB -> lt;
        0 when DocIdA == DocIdB -> eq;
        % when DocIdA > DocIdB
        0 -> gt;
        N when N > 0 -> gt
    end;
collate_rows(KeyA, KeyB) ->
    % When collating reduce group keys they don't
    % come with a docid.
    case couch_ejson_compare:less(KeyA, KeyB) of
        N when N < 0 -> lt;
        0 -> eq;
        N when N > 0 -> gt
    end.

validate_args(Args) ->
    validate_args(Args, []).

% This is mostly a copy of couch_validate:validate_args/1 but it doesn't
% update start / end keys and also throws a not_implemented error for reduce
%
validate_args(#mrargs{} = Args, Opts) ->
    GroupLevel = determine_group_level(Args),
    Reduce = Args#mrargs.reduce,

    case Reduce == undefined orelse is_boolean(Reduce) of
        true -> ok;
        _ -> mrverror(<<"Invalid `reduce` value.">>)
    end,

    case {Args#mrargs.view_type, Reduce} of
        {map, true} -> mrverror(<<"Reduce is invalid for map-only views.">>);
        _ -> ok
    end,

    case {Args#mrargs.view_type, GroupLevel, Args#mrargs.keys} of
        {red, exact, _} ->
            ok;
        {red, _, KeyList} when is_list(KeyList) ->
            Msg = <<"Multi-key fetches for reduce views must use `group=true`">>,
            mrverror(Msg);
        _ ->
            ok
    end,

    case Args#mrargs.keys of
        Keys when is_list(Keys) -> ok;
        undefined -> ok;
        _ -> mrverror(<<"`keys` must be an array of strings.">>)
    end,

    case {Args#mrargs.keys, Args#mrargs.start_key, Args#mrargs.end_key} of
        {undefined, _, _} ->
            ok;
        {[], _, _} ->
            ok;
        {[_ | _], undefined, undefined} ->
            ok;
        _ ->
            mrverror(<<
                "`keys` is incompatible with `key`"
                ", `start_key` and `end_key`"
            >>)
    end,

    case Args#mrargs.start_key_docid of
        undefined -> ok;
        SKDocId0 when is_binary(SKDocId0) -> ok;
        _ -> mrverror(<<"`start_key_docid` must be a string.">>)
    end,

    case Args#mrargs.end_key_docid of
        undefined -> ok;
        EKDocId0 when is_binary(EKDocId0) -> ok;
        _ -> mrverror(<<"`end_key_docid` must be a string.">>)
    end,

    case Args#mrargs.direction of
        fwd -> ok;
        rev -> ok;
        _ -> mrverror(<<"Invalid direction.">>)
    end,

    case {Args#mrargs.limit >= 0, Args#mrargs.limit == undefined} of
        {true, _} -> ok;
        {_, true} -> ok;
        _ -> mrverror(<<"`limit` must be a positive integer.">>)
    end,

    case Args#mrargs.skip < 0 of
        true -> mrverror(<<"`skip` must be >= 0">>);
        _ -> ok
    end,

    case {Args#mrargs.view_type, GroupLevel} of
        {red, exact} -> ok;
        {_, 0} -> ok;
        {red, Int} when is_integer(Int), Int >= 0 -> ok;
        {red, _} -> mrverror(<<"`group_level` must be >= 0">>);
        {map, _} -> mrverror(<<"Invalid use of grouping on a map view.">>)
    end,

    case Args#mrargs.stable of
        true -> ok;
        false -> ok;
        _ -> mrverror(<<"Invalid value for `stable`.">>)
    end,

    case Args#mrargs.update of
        true -> ok;
        false -> ok;
        lazy -> ok;
        _ -> mrverror(<<"Invalid value for `update`.">>)
    end,

    case is_boolean(Args#mrargs.inclusive_end) of
        true -> ok;
        _ -> mrverror(<<"Invalid value for `inclusive_end`.">>)
    end,

    case {Args#mrargs.view_type, Args#mrargs.include_docs} of
        {red, true} -> mrverror(<<"`include_docs` is invalid for reduce">>);
        {_, ID} when is_boolean(ID) -> ok;
        _ -> mrverror(<<"Invalid value for `include_docs`">>)
    end,

    case {Args#mrargs.view_type, Args#mrargs.conflicts} of
        {_, undefined} -> ok;
        {map, V} when is_boolean(V) -> ok;
        {red, undefined} -> ok;
        {map, _} -> mrverror(<<"Invalid value for `conflicts`.">>);
        {red, _} -> mrverror(<<"`conflicts` is invalid for reduce views.">>)
    end,

    case is_boolean(Args#mrargs.sorted) of
        true -> ok;
        _ -> mrverror(<<"Invalid value for `sorted`.">>)
    end,

    MaxPageSize = couch_util:get_value(page_size, Opts, 0),
    case {Args#mrargs.page_size, MaxPageSize} of
        {_, 0} -> ok;
        {Value, _} -> validate_limit(<<"page_size">>, Value, 1, MaxPageSize)
    end,

    case {Args#mrargs.skip, MaxPageSize} of
        {_, 0} -> ok;
        {Skip, _} -> validate_limit(<<"skip">>, Skip, 0, MaxPageSize)
    end,

    case {is_list(Args#mrargs.keys), is_integer(Args#mrargs.page_size)} of
        {true, true} ->
            mrverror(<<"`page_size` is incompatible with `keys`">>);
        _ ->
            ok
    end,

    case {Reduce, Args#mrargs.view_type} of
        {false, _} -> ok;
        {_, red} -> throw(not_implemented);
        _ -> ok
    end,

    Args#mrargs{group_level = GroupLevel}.

validate_limit(Name, Value, _Min, _Max) when not is_integer(Value) ->
    mrverror(<<"`", Name/binary, "` should be an integer">>);
validate_limit(Name, Value, Min, Max) when Value > Max ->
    range_error_msg(Name, Min, Max);
validate_limit(Name, Value, Min, Max) when Value < Min ->
    range_error_msg(Name, Min, Max);
validate_limit(_Name, _Value, _Min, _Max) ->
    ok.

range_error_msg(Name, Min, Max) ->
    MinBin = list_to_binary(integer_to_list(Min)),
    MaxBin = list_to_binary(integer_to_list(Max)),
    mrverror(<<
        "`",
        Name/binary,
        "` should be an integer in range [",
        MinBin/binary,
        " .. ",
        MaxBin/binary,
        "]"
    >>).

determine_group_level(#mrargs{group = undefined, group_level = undefined}) ->
    0;
determine_group_level(#mrargs{group = false, group_level = undefined}) ->
    0;
determine_group_level(#mrargs{group = false, group_level = Level}) when Level > 0 ->
    mrverror(<<"Can't specify group=false and group_level>0 at the same time">>);
determine_group_level(#mrargs{group = true, group_level = undefined}) ->
    exact;
determine_group_level(#mrargs{group_level = GroupLevel}) ->
    GroupLevel.

mrverror(Mesg) ->
    throw({query_parse_error, Mesg}).

is_paginated(#mrargs{page_size = PageSize}) when is_integer(PageSize) ->
    true;
is_paginated(_) ->
    false.

active_tasks_info(ChangesDone, DbName, DDocId, LastSeq, DBSeq) ->
    #{
        <<"type">> => <<"indexer">>,
        <<"database">> => DbName,
        <<"changes_done">> => ChangesDone,
        <<"design_document">> => DDocId,
        <<"current_version_stamp">> => convert_seq_to_stamp(LastSeq),
        <<"db_version_stamp">> => convert_seq_to_stamp(DBSeq),
        <<"node">> => erlang:atom_to_binary(node(), utf8),
        <<"pid">> => list_to_binary(pid_to_list(self()))
    }.

maybe_disable_custom_reduce_funs(Views) ->
    case config:get_boolean("couch_views", "custom_reduce_enabled", true) of
        true ->
            Views;
        false ->
            disable_custom_reduce_funs(Views)
    end.

disable_custom_reduce_funs(Views) ->
    lists:map(
        fun(View) ->
            #mrview{
                reduce_funs = ReduceFuns
            } = View,
            {Builtin, Custom} = lists:partition(
                fun({_Name, RedSrc}) ->
                    case RedSrc of
                        <<"_", _/binary>> -> true;
                        <<_/binary>> -> false
                    end
                end,
                ReduceFuns
            ),
            DisabledCustom = [{Name, disabled} || {Name, _Src} <- Custom],
            View#mrview{
                reduce_funs = Builtin ++ DisabledCustom
            }
        end,
        Views
    ).

convert_seq_to_stamp(<<"0">>) ->
    <<"0-0-0">>;
convert_seq_to_stamp(undefined) ->
    <<"0-0-0">>;
convert_seq_to_stamp(Seq) ->
    {_, Stamp, Batch, DocNumber} = fabric2_fdb:seq_to_vs(Seq),
    VS =
        integer_to_list(Stamp) ++ "-" ++ integer_to_list(Batch) ++ "-" ++
            integer_to_list(DocNumber),
    list_to_binary(VS).

get_view_queries({Props}) ->
    case couch_util:get_value(<<"queries">>, Props) of
        undefined ->
            undefined;
        Queries when is_list(Queries) ->
            Queries;
        _ ->
            throw({bad_request, "`queries` member must be an array."})
    end.

get_view_keys({Props}) ->
    case couch_util:get_value(<<"keys">>, Props) of
        undefined ->
            undefined;
        Keys when is_list(Keys) ->
            Keys;
        _ ->
            throw({bad_request, "`keys` member must be an array."})
    end.

sort_lib({Lib}) ->
    sort_lib(Lib, []).

sort_lib([], LAcc) ->
    lists:keysort(1, LAcc);
sort_lib([{LName, {LObj}} | Rest], LAcc) ->
    % descend into nested object
    LSorted = sort_lib(LObj, []),
    sort_lib(Rest, [{LName, LSorted} | LAcc]);
sort_lib([{LName, LCode} | Rest], LAcc) ->
    sort_lib(Rest, [{LName, LCode} | LAcc]).

index_of(Key, List) ->
    index_of(Key, List, 1).

index_of(_, [], _) ->
    throw({error, missing_named_view});
index_of(Key, [Key | _], Idx) ->
    Idx;
index_of(Key, [_ | Rest], Idx) ->
    index_of(Key, Rest, Idx + 1).
