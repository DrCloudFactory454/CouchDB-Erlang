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

-module(mango_eval).
-behavior(couch_eval).

-export([
    acquire_map_context/1,
    release_map_context/1,
    map_docs/2,
    acquire_context/0,
    release_context/1,
    try_compile/4,
    validate_doc_update/5,
    filter_view/3,
    filter_docs/5
]).

-export([
    index_doc/2
]).

-include_lib("couch/include/couch_db.hrl").
-include("mango_idx.hrl").

acquire_map_context(Opts) ->
    #{
        db_name := DbName,
        ddoc_id := DDocId,
        map_funs := MapFuns
    } = Opts,
    Indexes = lists:map(
        fun(Def) ->
            #idx{
                type = <<"json">>,
                dbname = DbName,
                ddoc = DDocId,
                def = Def
            }
        end,
        MapFuns
    ),
    {ok, Indexes}.

release_map_context(_) ->
    ok.

map_docs(Indexes, Docs) ->
    {ok,
        lists:map(
            fun(Doc) ->
                Json = couch_doc:to_json_obj(Doc, []),
                Results = index_doc(Indexes, Json),
                {Doc#doc.id, Results}
            end,
            Docs
        )}.

acquire_context() ->
    {ok, no_ctx}.

release_context(_) ->
    ok.

try_compile(_Ctx, _FunType, _IndexName, IndexInfo) ->
    mango_idx_view:validate_index_def(IndexInfo).

% Add these functions in so that it implements the couch_eval
% even though it is not supported
validate_doc_update(_DDoc, _EditDoc, _DiskDoc, _UserCtx, _SecObj) ->
    throw({not_supported}).

filter_view(_DDoc, _VName, _Docs) ->
    throw({not_supported}).

filter_docs(_Req, _Db, _DDoc, _FName, _Docs) ->
    throw({not_supported}).

index_doc(Indexes, Doc) ->
    lists:map(
        fun(Idx) ->
            {IdxDef} = mango_idx:def(Idx),
            Results = get_index_entries(IdxDef, Doc),
            case lists:member(not_found, Results) of
                true ->
                    [];
                false ->
                    [{Results, null}]
            end
        end,
        Indexes
    ).

get_index_entries(IdxDef, Doc) ->
    {Fields} = couch_util:get_value(<<"fields">>, IdxDef),
    Selector = get_index_partial_filter_selector(IdxDef),
    case should_index(Selector, Doc) of
        false ->
            [not_found];
        true ->
            get_index_values(Fields, Doc)
    end.

get_index_values(Fields, Doc) ->
    lists:map(
        fun({Field, _Dir}) ->
            case mango_doc:get_field(Doc, Field) of
                not_found -> not_found;
                bad_path -> not_found;
                Value -> Value
            end
        end,
        Fields
    ).

get_index_partial_filter_selector(IdxDef) ->
    case couch_util:get_value(<<"partial_filter_selector">>, IdxDef, {[]}) of
        {[]} ->
            % this is to support legacy text indexes that had the
            % partial_filter_selector set as selector
            couch_util:get_value(<<"selector">>, IdxDef, {[]});
        Else ->
            Else
    end.

should_index(Selector, Doc) ->
    NormSelector = mango_selector:normalize(Selector),
    Matches = mango_selector:match(NormSelector, Doc),
    IsDesign =
        case mango_doc:get_field(Doc, <<"_id">>) of
            <<"_design/", _/binary>> -> true;
            _ -> false
        end,
    Matches and not IsDesign.
