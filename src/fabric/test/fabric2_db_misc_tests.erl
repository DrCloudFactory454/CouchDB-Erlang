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

-module(fabric2_db_misc_tests).

% Used in events_listener test
-export([
    event_listener_callback/3
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch/include/couch_eunit.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("fabric2.hrl").
-include("fabric2_test.hrl").

misc_test_() ->
    {
        "Test database miscellaney",
        {
            setup,
            fun setup/0,
            fun cleanup/1,
            with([
                ?TDEF(empty_db_info),
                ?TDEF(accessors),
                ?TDEF(set_revs_limit),
                ?TDEF(set_security),
                ?TDEF(get_security_cached),
                ?TDEF(is_system_db),
                ?TDEF(validate_dbname),
                ?TDEF(validate_doc_ids),
                ?TDEF(get_doc_info),
                ?TDEF(get_doc_info_not_found),
                ?TDEF(get_full_doc_info),
                ?TDEF(get_full_doc_info_not_found),
                ?TDEF(get_full_doc_infos),
                ?TDEF(ensure_full_commit),
                ?TDEF(metadata_bump),
                ?TDEF(db_version_bump),
                ?TDEF(db_cache_doesnt_evict_newer_handles),
                ?TDEF(events_listener)
            ])
        }
    }.

setup() ->
    Ctx = test_util:start_couch([fabric]),
    DbName = ?tempdb(),
    {ok, Db} = fabric2_db:create(DbName, [{user_ctx, ?ADMIN_USER}]),
    {DbName, Db, Ctx}.

cleanup({_DbName, Db, Ctx}) ->
    meck:unload(),
    ok = fabric2_db:delete(fabric2_db:name(Db), []),
    test_util:stop_couch(Ctx).

empty_db_info({DbName, Db, _}) ->
    {ok, Info} = fabric2_db:get_db_info(Db),
    ?assertEqual(DbName, fabric2_util:get_value(db_name, Info)),
    ?assertEqual(0, fabric2_util:get_value(doc_count, Info)),
    ?assertEqual(0, fabric2_util:get_value(doc_del_count, Info)),
    ?assert(is_binary(fabric2_util:get_value(update_seq, Info))),
    InfoUUID = fabric2_util:get_value(uuid, Info),
    UUID = fabric2_db:get_uuid(Db),
    ?assertEqual(UUID, InfoUUID).

accessors({DbName, Db, _}) ->
    SeqZero = fabric2_fdb:vs_to_seq(fabric2_util:seq_zero_vs()),
    ?assertEqual(DbName, fabric2_db:name(Db)),
    ?assertEqual(0, fabric2_db:get_instance_start_time(Db)),
    ?assertEqual(nil, fabric2_db:get_pid(Db)),
    ?assertEqual(undefined, fabric2_db:get_before_doc_update_fun(Db)),
    ?assertEqual(undefined, fabric2_db:get_after_doc_read_fun(Db)),
    ?assertEqual(SeqZero, fabric2_db:get_committed_update_seq(Db)),
    ?assertEqual(SeqZero, fabric2_db:get_compacted_seq(Db)),
    ?assertEqual(SeqZero, fabric2_db:get_update_seq(Db)),
    ?assertEqual(nil, fabric2_db:get_compactor_pid(Db)),
    ?assertEqual(1000, fabric2_db:get_revs_limit(Db)),
    ?assertMatch(<<_:32/binary>>, fabric2_db:get_uuid(Db)),
    ?assertEqual(true, fabric2_db:is_db(Db)),
    ?assertEqual(false, fabric2_db:is_db(#{})),
    ?assertEqual(false, fabric2_db:is_partitioned(Db)),
    ?assertEqual(false, fabric2_db:is_clustered(Db)).

set_revs_limit({DbName, Db, _}) ->
    ?assertEqual(ok, fabric2_db:set_revs_limit(Db, 500)),
    {ok, Db2} = fabric2_db:open(DbName, []),
    ?assertEqual(500, fabric2_db:get_revs_limit(Db2)).

set_security({DbName, Db, _}) ->
    SecObj =
        {[
            {<<"admins">>,
                {[
                    {<<"names">>, []},
                    {<<"roles">>, []}
                ]}}
        ]},
    ?assertEqual(ok, fabric2_db:set_security(Db, SecObj)),
    {ok, Db2} = fabric2_db:open(DbName, []),
    ?assertEqual(SecObj, fabric2_db:get_security(Db2)).

get_security_cached({DbName, Db, _}) ->
    OldSecObj = fabric2_db:get_security(Db),
    SecObj =
        {[
            {<<"admins">>,
                {[
                    {<<"names">>, [<<"foo1">>]},
                    {<<"roles">>, []}
                ]}}
        ]},

    % Set directly so we don't auto-update the local cache
    {ok, Db1} = fabric2_db:open(DbName, [?ADMIN_CTX]),
    ?assertMatch(
        {ok, #{}},
        fabric2_fdb:transactional(Db1, fun(TxDb) ->
            fabric2_fdb:set_config(TxDb, security_doc, SecObj)
        end)
    ),

    {ok, Db2} = fabric2_db:open(DbName, [?ADMIN_CTX]),
    ?assertEqual(OldSecObj, fabric2_db:get_security(Db2, [{max_age, 1000}])),

    timer:sleep(100),
    ?assertEqual(SecObj, fabric2_db:get_security(Db2, [{max_age, 50}])),

    ?assertEqual(ok, fabric2_db:set_security(Db2, OldSecObj)).

is_system_db({DbName, Db, _}) ->
    ?assertEqual(false, fabric2_db:is_system_db(Db)),
    ?assertEqual(false, fabric2_db:is_system_db_name("foo")),
    ?assertEqual(false, fabric2_db:is_system_db_name(DbName)),
    ?assertEqual(true, fabric2_db:is_system_db_name(<<"_replicator">>)),
    ?assertEqual(true, fabric2_db:is_system_db_name("_replicator")),
    ?assertEqual(true, fabric2_db:is_system_db_name(<<"foo/_replicator">>)),
    ?assertEqual(false, fabric2_db:is_system_db_name(<<"f.o/_replicator">>)),
    ?assertEqual(false, fabric2_db:is_system_db_name(<<"foo/bar">>)).

validate_dbname(_) ->
    Tests = [
        {ok, <<"foo">>},
        {ok, "foo"},
        {ok, <<"_replicator">>},
        {error, illegal_database_name, <<"Foo">>},
        {error, illegal_database_name, <<"foo|bar">>},
        {error, illegal_database_name, <<"Foo">>},
        {error, database_name_too_long, <<
            "0123456789012345678901234567890123456789"
            "0123456789012345678901234567890123456789"
            "0123456789012345678901234567890123456789"
            "0123456789012345678901234567890123456789"
            "0123456789012345678901234567890123456789"
            "0123456789012345678901234567890123456789"
        >>}
    ],
    CheckFun = fun
        ({ok, DbName}) ->
            ?assertEqual(ok, fabric2_db:validate_dbname(DbName));
        ({error, Reason, DbName}) ->
            Expect = {error, {Reason, DbName}},
            ?assertEqual(Expect, fabric2_db:validate_dbname(DbName))
    end,
    try
        % Don't allow epi plugins to interfere with test results
        meck:new(couch_epi, [passthrough]),
        meck:expect(couch_epi, decide, 5, no_decision),
        lists:foreach(CheckFun, Tests)
    after
        % Unload within the test to minimize interference with other tests
        meck:unload()
    end.

validate_doc_ids(_) ->
    % Basic test with default max infinity length
    ?assertEqual(ok, fabric2_db:validate_docid(<<"foo">>)),

    Tests = [
        {ok, <<"_local/foo">>},
        {ok, <<"_design/foo">>},
        {ok, generate_long_doc_id(16)},
        {ok, generate_long_doc_id(512)},
        {illegal_docid, <<"">>},
        {illegal_docid, <<"_design/">>},
        {illegal_docid, <<"_local/">>},
        {illegal_docid, generate_long_doc_id(513)},
        {illegal_docid, <<16#FF>>},
        {illegal_docid, <<"_bad">>},
        {illegal_docid, null}
    ],
    CheckFun = fun
        ({ok, DocId}) ->
            ?assertEqual(ok, fabric2_db:validate_docid(DocId));
        ({illegal_docid, DocId}) ->
            ?assertThrow({illegal_docid, _}, fabric2_db:validate_docid(DocId))
    end,

    try
        meck:new(config, [passthrough]),
        meck:expect(
            config,
            get,
            ["couchdb", "max_document_id_length", "512"],
            "16"
        ),
        lists:foreach(CheckFun, Tests),

        % Check that fabric2_db_plugin can't allow for
        % underscore prefixed dbs
        meck:new(fabric2_db_plugin, [passthrough]),
        meck:expect(fabric2_db_plugin, validate_docid, ['_'], true),
        ?assertEqual(ok, fabric2_db:validate_docid(<<"_wheee">>))
    after
        % Unloading within the test as the config mock
        % interferes with the db version bump test.
        meck:unload()
    end.

generate_long_doc_id(Size) ->
    list_to_binary(string:copies("x", Size)).

get_doc_info({_, Db, _}) ->
    DocId = couch_uuids:random(),
    InsertDoc = #doc{
        id = DocId,
        body = {[{<<"foo">>, true}]}
    },
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, InsertDoc, []),

    DI = fabric2_db:get_doc_info(Db, DocId),
    ?assert(is_record(DI, doc_info)),
    #doc_info{
        id = DIDocId,
        high_seq = HighSeq,
        revs = Revs
    } = DI,

    ?assertEqual(DocId, DIDocId),
    ?assert(is_binary(HighSeq)),
    ?assertMatch([#rev_info{}], Revs),

    [
        #rev_info{
            rev = DIRev,
            seq = Seq,
            deleted = Deleted,
            body_sp = BodySp
        }
    ] = Revs,

    ?assertEqual({Pos, Rev}, DIRev),
    ?assert(is_binary(Seq)),
    ?assert(not Deleted),
    ?assertMatch(undefined, BodySp).

get_doc_info_not_found({_, Db, _}) ->
    DocId = couch_uuids:random(),
    ?assertEqual(not_found, fabric2_db:get_doc_info(Db, DocId)).

get_full_doc_info({_, Db, _}) ->
    DocId = couch_uuids:random(),
    InsertDoc = #doc{
        id = DocId,
        body = {[{<<"foo">>, true}]}
    },
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, InsertDoc, []),
    FDI = fabric2_db:get_full_doc_info(Db, DocId),

    ?assert(is_record(FDI, full_doc_info)),
    #full_doc_info{
        id = FDIDocId,
        update_seq = UpdateSeq,
        deleted = Deleted,
        rev_tree = RevTree,
        sizes = SizeInfo
    } = FDI,

    ?assertEqual(DocId, FDIDocId),
    ?assert(is_binary(UpdateSeq)),
    ?assert(not Deleted),
    ?assertMatch([{Pos, {Rev, _, []}}], RevTree),
    ?assertEqual(#size_info{}, SizeInfo).

get_full_doc_info_not_found({_, Db, _}) ->
    DocId = couch_uuids:random(),
    ?assertEqual(not_found, fabric2_db:get_full_doc_info(Db, DocId)).

get_full_doc_infos({_, Db, _}) ->
    DocIds = lists:map(
        fun(_) ->
            DocId = couch_uuids:random(),
            Doc = #doc{id = DocId},
            {ok, _} = fabric2_db:update_doc(Db, Doc, []),
            DocId
        end,
        lists:seq(1, 5)
    ),

    FDIs = fabric2_db:get_full_doc_infos(Db, DocIds),
    lists:zipwith(
        fun(DocId, FDI) ->
            ?assertEqual(DocId, FDI#full_doc_info.id)
        end,
        DocIds,
        FDIs
    ).

ensure_full_commit({_, Db, _}) ->
    ?assertEqual({ok, 0}, fabric2_db:ensure_full_commit(Db)),
    ?assertEqual({ok, 0}, fabric2_db:ensure_full_commit(Db, 5)).

metadata_bump({DbName, _, _}) ->
    % Call open again here to make sure we have a version in the cache
    % as we'll be checking if that version gets its metadata bumped
    {ok, Db} = fabric2_db:open(DbName, [{user_ctx, ?ADMIN_USER}]),

    % Emulate a remote client bumping the metadataversion
    {ok, Fdb} = application:get_env(fabric, db),
    erlfdb:transactional(Fdb, fun(Tx) ->
        erlfdb:set_versionstamped_value(Tx, ?METADATA_VERSION_KEY, <<0:112>>)
    end),
    NewMDVersion = erlfdb:transactional(Fdb, fun(Tx) ->
        erlfdb:wait(erlfdb:get(Tx, ?METADATA_VERSION_KEY))
    end),

    % Save timestamp before ensure_current/1 is called
    TsBeforeEnsureCurrent = erlang:monotonic_time(millisecond),

    % Perform a random operation which calls ensure_current
    {ok, _} = fabric2_db:get_db_info(Db),

    % Check that db handle in the cache got the new metadata version
    % and that check_current_ts was updated
    CachedDb = fabric2_server:fetch(DbName, undefined),
    ?assertMatch(
        #{
            md_version := NewMDVersion,
            check_current_ts := Ts
        } when Ts >= TsBeforeEnsureCurrent,
        CachedDb
    ).

db_version_bump({DbName, _, _}) ->
    % Call open again here to make sure we have a version in the cache
    % as we'll be checking if that version gets its metadata bumped
    {ok, Db} = fabric2_db:open(DbName, [{user_ctx, ?ADMIN_USER}]),

    % Emulate a remote client bumping db version. We don't go through the
    % regular db open + update security doc or something like that to make sure
    % we don't touch the local cache
    #{db_prefix := DbPrefix} = Db,
    DbVersionKey = erlfdb_tuple:pack({?DB_VERSION}, DbPrefix),
    {ok, Fdb} = application:get_env(fabric, db),
    NewDbVersion = fabric2_util:uuid(),
    erlfdb:transactional(Fdb, fun(Tx) ->
        erlfdb:set(Tx, DbVersionKey, NewDbVersion),
        erlfdb:set_versionstamped_value(Tx, ?METADATA_VERSION_KEY, <<0:112>>)
    end),

    % Perform a random operation which calls ensure_current
    {ok, _} = fabric2_db:get_db_info(Db),

    % After previous operation, the cache should have been cleared
    ?assertMatch(undefined, fabric2_server:fetch(DbName, undefined)),

    % Call open again and check that we have the latest db version
    {ok, Db2} = fabric2_db:open(DbName, [{user_ctx, ?ADMIN_USER}]),

    % Check that db handle in the cache got the new metadata version
    ?assertMatch(#{db_version := NewDbVersion}, Db2).

db_cache_doesnt_evict_newer_handles({DbName, _, _}) ->
    {ok, Db} = fabric2_db:open(DbName, [{user_ctx, ?ADMIN_USER}]),
    CachedDb = fabric2_server:fetch(DbName, undefined),

    StaleDb = Db#{md_version := <<0>>},

    ok = fabric2_server:store(StaleDb),
    ?assertEqual(CachedDb, fabric2_server:fetch(DbName, undefined)),

    ?assert(not fabric2_server:maybe_update(StaleDb)),
    ?assertEqual(CachedDb, fabric2_server:fetch(DbName, undefined)),

    ?assert(not fabric2_server:maybe_remove(StaleDb)),
    ?assertEqual(CachedDb, fabric2_server:fetch(DbName, undefined)).

events_listener({DbName, Db, _}) ->
    Opts = [
        {dbname, DbName},
        {uuid, fabric2_db:get_uuid(Db)},
        {timeout, 100}
    ],

    Fun = event_listener_callback,
    {ok, Pid} = fabric2_events:link_listener(?MODULE, Fun, self(), Opts),
    unlink(Pid),
    Ref = monitor(process, Pid),

    NextEvent = fun(Timeout) ->
        receive
            {Pid, Evt} when is_pid(Pid) -> Evt;
            {'DOWN', Ref, _, _, normal} -> exited_normal
        after Timeout ->
            timeout
        end
    end,

    Doc1 = #doc{id = couch_uuids:random()},
    {ok, _} = fabric2_db:update_doc(Db, Doc1, []),
    ?assertEqual(updated, NextEvent(1000)),

    % Just one update, then expect a timeout
    ?assertEqual(timeout, NextEvent(500)),

    Doc2 = #doc{id = couch_uuids:random()},
    {ok, _} = fabric2_db:update_doc(Db, Doc2, []),
    ?assertEqual(updated, NextEvent(1000)),

    % Process is still alive
    ?assert(is_process_alive(Pid)),

    % Recreate db
    ok = fabric2_db:delete(DbName, [?ADMIN_CTX]),
    {ok, _} = fabric2_db:create(DbName, [?ADMIN_CTX]),
    ?assertEqual(deleted, NextEvent(1000)),

    % After db is deleted or re-created listener should die
    ?assertEqual(exited_normal, NextEvent(1000)).

% Callback for event_listener function
event_listener_callback(_DbName, Event, TestPid) ->
    TestPid ! {self(), Event},
    {ok, TestPid}.
