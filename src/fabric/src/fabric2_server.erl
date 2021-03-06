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

-module(fabric2_server).
-behaviour(gen_server).
-vsn(1).

-export([
    start_link/0,

    fetch/2,

    store/1,
    maybe_update/1,

    remove/1,
    maybe_remove/1,

    fdb_directory/0,
    fdb_cluster/0,
    get_retry_limit/0
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-include("fabric2.hrl").

-define(CLUSTER_FILE_MACOS, "/usr/local/etc/foundationdb/fdb.cluster").
-define(CLUSTER_FILE_LINUX, "/etc/foundationdb/fdb.cluster").
-define(CLUSTER_FILE_WIN32, "C:/ProgramData/foundationdb/fdb.cluster").
-define(FDB_DIRECTORY, fdb_directory).
-define(FDB_CLUSTER, fdb_cluster).
-define(DEFAULT_FDB_DIRECTORY, <<"couchdb">>).
-define(TX_OPTIONS_SECTION, "fdb_tx_options").
-define(RELISTEN_DELAY, 1000).

-define(DEFAULT_TIMEOUT_MSEC, "60000").
-define(DEFAULT_RETRY_LIMIT, "100").

-define(TX_OPTIONS, #{
    machine_id => {binary, undefined},
    datacenter_id => {binary, undefined},
    transaction_logging_max_field_length => {integer, undefined},
    timeout => {integer, ?DEFAULT_TIMEOUT_MSEC},
    retry_limit => {integer, ?DEFAULT_RETRY_LIMIT},
    max_retry_delay => {integer, undefined},
    size_limit => {integer, undefined}
}).

-define(CONFIG_LIMITS, [
    {"couchdb", "max_document_size", ?DOCUMENT_SIZE_LIMIT_BYTES},
    {"couchdb", "max_attachment_size", ?ATT_SIZE_LIMIT_BYTES},
    {"couchdb", "max_document_id_length", ?DOC_ID_LIMIT_BYTES},
    {"fabric", "binary_chunk_size", ?DEFAULT_BINARY_CHUNK_SIZE_BYTES}
]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

fetch(DbName, UUID) when is_binary(DbName) ->
    case {UUID, ets:lookup(?MODULE, DbName)} of
        {_, []} -> undefined;
        {undefined, [{DbName, _UUID, _, #{} = Db}]} -> Db;
        {<<_/binary>>, [{DbName, UUID, _, #{} = Db}]} -> Db;
        {<<_/binary>>, [{DbName, _UUID, _, #{} = _Db}]} -> undefined
    end.

store(#{name := DbName} = Db0) when is_binary(DbName) ->
    #{
        uuid := UUID,
        md_version := MDVer
    } = Db0,
    Db1 = sanitize(Db0),
    case ets:insert_new(?MODULE, {DbName, UUID, MDVer, Db1}) of
        true -> ok;
        false -> maybe_update(Db1)
    end,
    ok.

maybe_update(#{name := DbName} = Db0) when is_binary(DbName) ->
    #{
        uuid := UUID,
        md_version := MDVer
    } = Db0,
    Db1 = sanitize(Db0),
    Head = {DbName, UUID, '$1', '_'},
    Guard = {'=<', '$1', MDVer},
    Body = {DbName, UUID, MDVer, {const, Db1}},
    try
        1 =:= ets:select_replace(?MODULE, [{Head, [Guard], [{Body}]}])
    catch
        error:badarg ->
            false
    end.

remove(DbName) when is_binary(DbName) ->
    true = ets:delete(?MODULE, DbName),
    ok.

maybe_remove(#{name := DbName} = Db) when is_binary(DbName) ->
    #{
        uuid := UUID,
        md_version := MDVer
    } = Db,
    Head = {DbName, UUID, '$1', '_'},
    Guard = {'=<', '$1', MDVer},
    1 =:= ets:select_delete(?MODULE, [{Head, [Guard], [true]}]).

init(_) ->
    ets:new(?MODULE, [
        public,
        named_table,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {Cluster, Db} = get_db_and_cluster([empty]),
    application:set_env(fabric, ?FDB_CLUSTER, Cluster),
    application:set_env(fabric, db, Db),

    Dir =
        case config:get("fabric", "fdb_directory") of
            Val when is_list(Val), length(Val) > 0 ->
                [?l2b(Val)];
            _ ->
                [?DEFAULT_FDB_DIRECTORY]
        end,
    application:set_env(fabric, ?FDB_DIRECTORY, Dir),
    config:subscribe_for_changes([?TX_OPTIONS_SECTION]),
    check_config_limits(),
    {ok, nil}.

check_config_limits() ->
    lists:foreach(
        fun({Sect, Key, Limit}) ->
            ConfigVal = config:get_integer(Sect, Key, Limit),
            case ConfigVal > Limit of
                true ->
                    LogMsg = "Config value of ~p for [~s] ~s is greater than the limit: ~p",
                    couch_log:warning(LogMsg, [ConfigVal, Sect, Key, Limit]);
                false ->
                    ok
            end
        end,
        ?CONFIG_LIMITS
    ).

terminate(_, _St) ->
    ok.

handle_call(Msg, _From, St) ->
    {stop, {bad_call, Msg}, {bad_call, Msg}, St}.

handle_cast(Msg, St) ->
    {stop, {bad_cast, Msg}, St}.

handle_info({config_change, ?TX_OPTIONS_SECTION, _K, deleted, _}, St) ->
    % Since we don't know the exact default values to reset the options
    % to we recreate the db handle instead which will start with a default
    % handle and re-apply all the options
    {_Cluster, NewDb} = get_db_and_cluster([]),
    application:set_env(fabric, db, NewDb),
    {noreply, St};
handle_info({config_change, ?TX_OPTIONS_SECTION, K, V, _}, St) ->
    {ok, Db} = application:get_env(fabric, db),
    apply_tx_options(Db, [{K, V}]),
    {noreply, St};
handle_info({gen_event_EXIT, _Handler, _Reason}, St) ->
    erlang:send_after(?RELISTEN_DELAY, self(), restart_config_listener),
    {noreply, St};
handle_info(restart_config_listener, St) ->
    config:subscribe_for_changes([?TX_OPTIONS_SECTION]),
    {noreply, St};
handle_info(Msg, St) ->
    {stop, {bad_info, Msg}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

fdb_directory() ->
    get_env(?FDB_DIRECTORY).

fdb_cluster() ->
    get_env(?FDB_CLUSTER).

get_retry_limit() ->
    Default = list_to_integer(?DEFAULT_RETRY_LIMIT),
    config:get_integer(?TX_OPTIONS_SECTION, "retry_limit", Default).

get_env(Key) ->
    case get(Key) of
        undefined ->
            case application:get_env(fabric, Key) of
                undefined ->
                    erlang:error(fabric_application_not_started);
                {ok, Value} ->
                    put(Key, Value),
                    Value
            end;
        Value ->
            Value
    end.

get_db_and_cluster(EunitDbOpts) ->
    {Cluster, Db} =
        case application:get_env(fabric, eunit_run) of
            {ok, true} ->
                {<<"eunit_test">>, erlfdb_util:get_test_db(EunitDbOpts)};
            undefined ->
                ClusterFileStr = get_cluster_file_path(),
                {ok, ConnectionStr} = file:read_file(ClusterFileStr),
                DbHandle = erlfdb:open(iolist_to_binary(ClusterFileStr)),
                {string:trim(ConnectionStr), DbHandle}
        end,
    apply_tx_options(Db, config:get(?TX_OPTIONS_SECTION)),
    {Cluster, Db}.

get_cluster_file_path() ->
    Locations =
        [
            {custom, config:get("erlfdb", "cluster_file")},
            {custom, os:getenv("FDB_CLUSTER_FILE", undefined)}
        ] ++ default_locations(os:type()),
    case find_cluster_file(Locations) of
        {ok, Location} ->
            Location;
        {error, Reason} ->
            erlang:error(Reason)
    end.

default_locations({unix, _}) ->
    [
        {default, ?CLUSTER_FILE_MACOS},
        {default, ?CLUSTER_FILE_LINUX}
    ];
default_locations({win32, _}) ->
    [
        {default, ?CLUSTER_FILE_WIN32}
    ].

find_cluster_file([]) ->
    {error, cluster_file_missing};
find_cluster_file([{custom, undefined} | Rest]) ->
    find_cluster_file(Rest);
find_cluster_file([{Type, Location} | Rest]) ->
    Msg = #{
        what => fdb_connection_setup,
        configuration_type => Type,
        cluster_file => Location
    },
    case file:read_file_info(Location, [posix]) of
        {ok, #file_info{access = read_write}} ->
            ?LOG_INFO(Msg#{status => ok}),
            couch_log:info(
                "Using ~s FDB cluster file: ~s",
                [Type, Location]
            ),
            {ok, Location};
        {ok, #file_info{access = read}} ->
            ?LOG_WARNING(Msg#{
                status => read_only_file,
                details =>
                    "If coordinators are changed without updating this "
                    "file CouchDB may be unable to connect to the FDB cluster!"
            }),
            couch_log:warning(
                "Using read-only ~s FDB cluster file: ~s -- if coordinators "
                "are changed without updating this file CouchDB may be unable "
                "to connect to the FDB cluster!",
                [Type, Location]
            ),
            {ok, Location};
        {ok, _} ->
            ?LOG_ERROR(Msg#{
                status => permissions_error,
                details => "CouchDB needs read/write access to FDB cluster file"
            }),
            couch_log:error(
                "CouchDB needs read/write access to FDB cluster file: ~s",
                [Location]
            ),
            {error, cluster_file_permissions};
        {error, Reason} when Type =:= custom ->
            ?LOG_ERROR(Msg#{
                status => Reason,
                details => file:format_error(Reason)
            }),
            couch_log:error(
                "Encountered ~p error looking for FDB cluster file: ~s",
                [Reason, Location]
            ),
            {error, Reason};
        {error, enoent} when Type =:= default ->
            ?LOG_INFO(Msg#{
                status => enoent,
                details => file:format_error(enoent)
            }),
            couch_log:info(
                "No FDB cluster file found at ~s",
                [Location]
            ),
            find_cluster_file(Rest);
        {error, Reason} when Type =:= default ->
            ?LOG_WARNING(Msg#{
                status => Reason,
                details => file:format_error(Reason)
            }),
            couch_log:warning(
                "Encountered ~p error looking for FDB cluster file: ~s",
                [Reason, Location]
            ),
            find_cluster_file(Rest)
    end.

apply_tx_options(Db, Cfg) ->
    maps:map(
        fun(Option, {Type, Default}) ->
            case lists:keyfind(atom_to_list(Option), 1, Cfg) of
                false ->
                    case Default of
                        undefined -> ok;
                        _Defined -> apply_tx_option(Db, Option, Default, Type)
                    end;
                {_K, Val} ->
                    apply_tx_option(Db, Option, Val, Type)
            end
        end,
        ?TX_OPTIONS
    ).

apply_tx_option(Db, Option, Val, integer) ->
    try
        set_option(Db, Option, list_to_integer(Val))
    catch
        error:badarg ->
            ?LOG_ERROR(#{
                what => invalid_transaction_option_value,
                option => Option,
                value => Val
            }),
            Msg = "~p : Invalid integer tx option ~p = ~p",
            couch_log:error(Msg, [?MODULE, Option, Val])
    end;
apply_tx_option(Db, Option, Val, binary) ->
    BinVal = list_to_binary(Val),
    case size(BinVal) < 16 of
        true ->
            set_option(Db, Option, BinVal);
        false ->
            ?LOG_ERROR(#{
                what => invalid_transaction_option_value,
                option => Option,
                value => Val,
                details => "string transaction option must be less than 16 bytes"
            }),
            Msg = "~p : String tx option ~p is larger than 16 bytes",
            couch_log:error(Msg, [?MODULE, Option])
    end.

set_option(Db, Option, Val) ->
    try
        erlfdb:set_option(Db, Option, Val)
    catch
        % This could happen if the option is not supported by erlfdb or
        % fdbsever.
        error:badarg ->
            ?LOG_ERROR(#{
                what => transaction_option_error,
                option => Option,
                value => Val
            }),
            Msg = "~p : Could not set fdb tx option ~p = ~p",
            couch_log:error(Msg, [?MODULE, Option, Val])
    end.

sanitize(#{} = Db) ->
    Db#{
        tx := undefined,
        user_ctx := #user_ctx{},
        security_fun := undefined,
        interactive := false
    }.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    meck:new(file, [unstick, passthrough]),
    meck:expect(file, read_file_info, fun
        ("ok.cluster", _) ->
            {ok, #file_info{access = read_write}};
        ("readonly.cluster", _) ->
            {ok, #file_info{access = read}};
        ("noaccess.cluster", _) ->
            {ok, #file_info{access = none}};
        ("missing.cluster", _) ->
            {error, enoent};
        (Path, Options) ->
            meck:passthrough([Path, Options])
    end).

teardown(_) ->
    meck:unload().

find_cluster_file_test_() ->
    {setup, fun setup/0, fun teardown/1, [
        {"ignore unspecified config",
            ?_assertEqual(
                {ok, "ok.cluster"},
                find_cluster_file([
                    {custom, undefined},
                    {custom, "ok.cluster"}
                ])
            )},

        {"allow read-only file",
            ?_assertEqual(
                {ok, "readonly.cluster"},
                find_cluster_file([
                    {custom, "readonly.cluster"}
                ])
            )},

        {"fail if no access to configured cluster file",
            ?_assertEqual(
                {error, cluster_file_permissions},
                find_cluster_file([
                    {custom, "noaccess.cluster"}
                ])
            )},

        {"fail if configured cluster file is missing",
            ?_assertEqual(
                {error, enoent},
                find_cluster_file([
                    {custom, "missing.cluster"},
                    {default, "ok.cluster"}
                ])
            )},

        {"check multiple default locations",
            ?_assertEqual(
                {ok, "ok.cluster"},
                find_cluster_file([
                    {default, "missing.cluster"},
                    {default, "ok.cluster"}
                ])
            )}
    ]}.

-endif.
