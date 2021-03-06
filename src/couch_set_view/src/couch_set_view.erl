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

-module(couch_set_view).
-behaviour(gen_server).

% public API
-export([start_link/0]).

-export([get_map_view/4, get_reduce_view/4]).
-export([get_group/3, get_group_pid/2, release_group/1, define_group/3]).
-export([get_group_info/2, cleanup_index_files/1, set_index_dir/2]).
-export([get_group_data_size/2]).

-export([is_view_defined/2]).
-export([set_partition_states/5, add_replica_partitions/3, remove_replica_partitions/3]).
-export([mark_partitions_unindexable/3, mark_partitions_indexable/3]).
-export([monitor_partition_update/3, demonitor_partition_update/3]).

-export([fold/5, fold_reduce/6]).
-export([get_row_count/2, reduce_to_count/1, extract_map_view/1]).

-export([less_json/2, less_json_ids/2]).

-export([handle_db_event/1]).

% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-include("couch_db.hrl").
-include_lib("couch_index_merger/include/couch_index_merger.hrl").
-include_lib("couch_index_merger/include/couch_view_merger.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").


-record(server, {
    root_dir = [],
    db_notifier
}).

-record(merge_acc, {
    fold_fun,
    acc
}).


% For a "set view" we have multiple databases which are indexed.
% The set has a name which is a prefix common to all source databases.
% Each database is designated as a "partition" and internally identified
% with an integer between 0 and N - 1 (N is total number of partitions).
% For example, if the set name is "myset", and the number of partitions
% is 4, then the "set view" indexer will index the following 4 databases:
%
%    "myset/0", "myset/1", "myset/2" and "myset/3"
%
% Not all paritions are necessarily indexed, so when the set view is created,
% the caller should specify not only the set name but also:
% 1) Total number of partitions
% 2) A list of active partition IDs
%
% Once a view is created, the caller can (via other APIs):
% 1) Change the list of active partitions (add or remove)
% 2) Add several "passive" partitions - these are partitions that are
%    indexed but whose results are not included in queries
% 3) Define a list of partitions to cleanup from the index. All
%    the view key/values that originated from any of these
%    partitions will eventually be removed from the index
%
-spec get_group(binary(),
                binary() | #doc{},
                #set_view_group_req{}) -> {'ok', #set_view_group{}}.
get_group(SetName, DDoc, Req) ->
    GroupPid = get_group_pid(SetName, DDoc),
    case couch_set_view_group:request_group(GroupPid, Req) of
    {ok, Group} ->
        {ok, Group};
    {error, view_undefined} ->
        % caller must call ?MODULE:define_group/3
        throw(view_undefined);
    Error ->
        throw(Error)
    end.


-spec get_group_pid(binary(), binary() | #doc{}) -> pid().
get_group_pid(SetName, #doc{} = DDoc) ->
    Group = couch_set_view_util:design_doc_to_set_view_group(SetName, DDoc),
    get_group_server(SetName, Group);
get_group_pid(SetName, DDocId) when is_binary(DDocId) ->
    get_group_server(SetName, open_set_group(SetName, DDocId)).


-spec release_group(#set_view_group{}) -> no_return().
release_group(Group) ->
    couch_set_view_group:release_group(Group).


-spec define_group(binary(), binary(), #set_view_params{}) -> 'ok'.
define_group(SetName, DDocId, #set_view_params{} = Params) ->
    GroupPid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:define_view(GroupPid, Params) of
    ok ->
        ok;
    Error ->
        throw(Error)
    end.


-spec is_view_defined(binary(), binary()) -> boolean().
is_view_defined(SetName, DDocId) ->
    GroupPid = get_group_pid(SetName, DDocId),
    couch_set_view_group:is_view_defined(GroupPid).


% This is an incremental operation. That is, the following sequence of calls:
%
% set_partitions_states(<<"myset">>, <<"_design/foo">>, [0, 1], [5], [8])
% set_partitions_states(<<"myset">>, <<"_design/foo">>, [2, 3], [6, 7], [9])
% set_partitions_states(<<"myset">>, <<"_design/foo">>, [], [], [10])
%
% Will cause the set view index to have the following state:
%
%   active partitions:   [0, 1, 2, 3]
%   passive partitions:  [5, 6, 7]
%   cleanup partitions:  [8, 9, 10]
%
% Also, to move partition(s) from one state to another, simply do a call
% where that partition(s) is listed in the new desired state. Example:
%
% set_partitions_states(<<"myset">>, <<"_design/foo">>, [0, 1, 2], [3], [4])
% set_partitions_states(<<"myset">>, <<"_design/foo">>, [], [2], [])
%
% This will result in the following set view index state:
%
%   active partitions:   [0, 1]
%   passive_partitions:  [2, 3]
%   cleanup_partitions:  [4]
%
% (partition 2 was first set to active state and then moved into the passive state)
%
% New partitions are added by specifying them for the first time in the active
% or passive state lists.
%
% If a request asks to set to active a partition that is currently marked as a
% replica partition, data from that partition will start to be transfered from
% the replica index into the main index.
%
-spec set_partition_states(binary(),
                           binary(),
                           [partition_id()],
                           [partition_id()],
                           [partition_id()]) -> 'ok'.
set_partition_states(SetName, DDocId, ActivePartitions, PassivePartitions, CleanupPartitions) ->
    GroupPid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:set_state(
        GroupPid, ActivePartitions, PassivePartitions, CleanupPartitions) of
    ok ->
        ok;
    Error ->
        throw(Error)
    end.


% Mark a set of partitions as replicas. They will be indexed in the replica index.
% This will only work if the view was defined with the option "use_replica_index".
%
% All the given partitions must not be in the active nor passive state.
% Like set_partition_states, this is an incremental operation.
%
-spec add_replica_partitions(binary(), binary(), [partition_id()]) -> 'ok'.
add_replica_partitions(SetName, DDocId, Partitions) ->
    GroupPid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:add_replica_partitions(
        GroupPid, Partitions) of
    ok ->
        ok;
    Error ->
        throw(Error)
    end.


% Unmark a set of partitions as replicas. Their data will be cleaned from the
% replica index. This will only work if the view was defined with the option
% "use_replica_index".
%
% This is a no-op for partitions not currently marked as replicas.
% Like set_partition_states, this is an incremental operation.
%
-spec remove_replica_partitions(binary(), binary(), [partition_id()]) -> 'ok'.
remove_replica_partitions(SetName, DDocId, Partitions) ->
    GroupPid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:remove_replica_partitions(
        GroupPid, Partitions) of
    ok ->
        ok;
    Error ->
        throw(Error)
    end.


% Mark a set of partitions, currently either in the active or passive states, as
% unindexable. This means future index updates will ignore new changes found in the
% corresponding partition databases. This operation doesn't remove any data from
% the index, nor does it start any cleanup operation. Queries will still see
% and get data from the corresponding partitions.
-spec mark_partitions_unindexable(binary(), binary(), [partition_id()]) -> 'ok'.
mark_partitions_unindexable(SetName, DDocId, Partitions) ->
    Pid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:mark_as_unindexable(Pid, Partitions) of
    ok ->
        ok;
    Error ->
        throw(Error)
    end.


% This is the counterpart of mark_partitions_unindexable/3. It marks a set of partitions
% as indexable again, meaning future index updates will process all new partition database
% changes (changes that happened since the last index update prior to the
% mark_partitions_unindexable/3 call). The given partitions are currently in either the
% active or passive states and were marked as unindexable before.
-spec mark_partitions_indexable(binary(), binary(), [partition_id()]) -> 'ok'.
mark_partitions_indexable(SetName, DDocId, Partitions) ->
    Pid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:mark_as_indexable(Pid, Partitions) of
    ok ->
        ok;
    Error ->
        throw(Error)
    end.


% Allow a caller to be notified, via a message, when a particular partition is
% up to date in the index (its current database sequence number matches the
% one in the index for that partition).
% When the partition is up to date, the caller will receive a message with the
% following shape:
%
%    {Ref::reference(), updated}
%
% Where the reference is the one returned when this function is called.
% If the underlying view group process dies before the partition is up to date,
% the caller will receive a message with the following shape:
%
%    {Ref::reference(), {shutdown, Reason::term()}}
%
% If the requested partition is marked for cleanup (because some process asked
% for that or the partition's database was deleted), the caller will receive a
% message with the following shape:
%
%    {Ref::reference(), marked_for_cleanup}
%
% The target partition must be either an active or passive partition.
% Replica partitions are not supported at the moment.
-spec monitor_partition_update(binary(), binary(), partition_id()) -> reference().
monitor_partition_update(SetName, DDocId, PartitionId) ->
    Ref = make_ref(),
    Pid = get_group_pid(SetName, DDocId),
    case couch_set_view_group:monitor_partition_update(Pid, PartitionId, Ref, self()) of
    ok ->
        Ref;
    Error ->
        throw(Error)
    end.


% Stop monitoring for notification of when a partition is fully indexed.
% This is a counter part to monitor_partition_update/3. This call flushes
% any monitor messsages from the callers mailbox.
-spec demonitor_partition_update(binary(), binary(), reference()) -> 'ok'.
demonitor_partition_update(SetName, DDocId, Ref) ->
    receive
    {Ref, _} ->
        ok
    after 0 ->
        Pid = get_group_pid(SetName, DDocId),
        ok = couch_set_view_group:demonitor_partition_update(Pid, Ref),
        receive
        {Ref, _} ->
            ok
        after 0 ->
            ok
        end
    end.


-spec get_group_server(binary(), #set_view_group{}) -> pid().
get_group_server(SetName, #set_view_group{sig = Sig} = Group) ->
    case ets:lookup(couch_sig_to_setview_pid, {SetName, Sig}) of
    [{_, Pid}] when is_pid(Pid) ->
        Pid;
    _ ->
        case gen_server:call(?MODULE, {get_group_server, SetName, Group}, infinity) of
        {ok, Pid} ->
            Pid;
        Error ->
            throw(Error)
        end
    end.


-spec open_set_group(binary(), binary()) -> #set_view_group{}.
open_set_group(SetName, GroupId) ->
    case couch_set_view_group:open_set_group(SetName, GroupId) of
    {ok, Group} ->
        Group;
    Error ->
        throw(Error)
    end.


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


get_group_info(SetName, DDocId) ->
    GroupPid = get_group_pid(SetName, DDocId),
    {ok, _Info} = couch_set_view_group:request_group_info(GroupPid).


get_group_data_size(SetName, DDocId) ->
    GroupPid = get_group_pid(SetName, DDocId),
    {ok, _Info} = couch_set_view_group:get_data_size(GroupPid).


cleanup_index_files(SetName) ->
    % load all ddocs
    {ok, Db} = couch_db:open_int(?master_dbname(SetName), []),
    {ok, DesignDocs} = couch_db:get_design_docs(Db),
    couch_db:close(Db),

    % make unique list of group sigs
    Sigs = lists:map(fun(#doc{id = GroupId}) ->
            GroupPid = get_group_pid(SetName, GroupId),
            {ok, Sig} = gen_server:call(GroupPid, get_sig, infinity),
            couch_util:to_hex(Sig)
        end,
        [DD || DD <- DesignDocs, not DD#doc.deleted]),

    FileList = list_index_files(SetName),

    % regex that matches all ddocs
    RegExp = "("++ string:join(Sigs, "|") ++")",

    % filter out the ones in use
    DeleteFiles = case Sigs of
    [] ->
        FileList;
    _ ->
        [FilePath || FilePath <- FileList,
            re:run(FilePath, RegExp, [{capture, none}]) =:= nomatch]
    end,
    % delete unused files
    case DeleteFiles of
    [] ->
        ok;
    _ ->
        ?LOG_INFO("Deleting unused (old) set view `~s` index files:~n~n~s",
            [SetName, string:join(DeleteFiles, "\n")])
    end,
    RootDir = couch_config:get("couchdb", "view_index_dir"),
    lists:foreach(
        fun(File) -> couch_file:delete(RootDir, File, false) end,
        DeleteFiles).

list_index_files(SetName) ->
    % call server to fetch the index files
    RootDir = couch_config:get("couchdb", "view_index_dir"),
    filelib:wildcard(filename:join([set_index_dir(RootDir, SetName), "*"])).


-spec get_row_count(#set_view_group{}, #set_view{}) -> non_neg_integer().
get_row_count(#set_view_group{replica_group = nil}, #set_view{btree = Bt}) ->
    {ok, {Count, _Reds, _AllPartitionsBitMaps}} = couch_btree:full_reduce(Bt),
    Count;
get_row_count(#set_view_group{replica_group = RepGroup}, View) ->
    RepView = lists:nth(View#set_view.id_num + 1, RepGroup#set_view_group.views),
    {ok, {CountMain, _, _}} = couch_btree:full_reduce(View#set_view.btree),
    {ok, {CountRep, _, _}} = couch_btree:full_reduce(RepView#set_view.btree),
    CountMain + CountRep.


extract_map_view({reduce, _N, View}) ->
    View.


-spec fold_reduce(#set_view_group{},
                  {'reduce', non_neg_integer(), #set_view{}},
                  set_view_fold_reduce_fun(),
                  term(),
                  set_view_key_group_fun(),
                  #view_query_args{}) -> {'ok', term()}.
fold_reduce(#set_view_group{replica_group = #set_view_group{} = RepGroup} = Group, View, FoldFun, FoldAcc, _KeyGroupFun, ViewQueryArgs) ->
    {reduce, NthRed, #set_view{id_num = Id}} = View,
    RepView = {reduce, NthRed, lists:nth(Id + 1, RepGroup#set_view_group.views)},
    ViewSpecs = [
        #set_view_spec{
            name = Group#set_view_group.set_name,
            ddoc_id = Group#set_view_group.name,
            view_name = ViewQueryArgs#view_query_args.view_name,
            partitions = [],  % not needed in this context
            group = Group#set_view_group{replica_group = nil},
            view = View
        },
        #set_view_spec{
            name = RepGroup#set_view_group.set_name,
            ddoc_id = RepGroup#set_view_group.name,
            view_name = ViewQueryArgs#view_query_args.view_name,
            partitions = [],  % not needed in this context
            group = RepGroup,
            view = RepView
        }
    ],
    MergeParams = #index_merge{
        indexes = ViewSpecs,
        callback = fun reduce_view_merge_callback/2,
        user_acc = #merge_acc{fold_fun = FoldFun, acc = FoldAcc},
        user_ctx = #user_ctx{roles = [<<"_admin">>]},
        http_params = ViewQueryArgs,
        extra = #view_merge{
            keys = ViewQueryArgs#view_query_args.keys,
            make_row_fun = fun(RowData) -> RowData end
        }
    },
    #merge_acc{acc = FinalAcc} = couch_index_merger:query_index(couch_view_merger, MergeParams),
    {ok, FinalAcc};

fold_reduce(Group, View, FoldFun, FoldAcc, KeyGroupFun, #view_query_args{keys = nil} = ViewQueryArgs) ->
    Options = [{key_group_fun, KeyGroupFun} | couch_set_view_util:make_key_options(ViewQueryArgs)],
    do_fold_reduce(Group, View, FoldFun, FoldAcc, Options);

fold_reduce(Group, View, FoldFun, FoldAcc, KeyGroupFun, #view_query_args{keys = Keys} = ViewQueryArgs0) ->
    {_, FinalAcc} = lists:foldl(
        fun(Key, {_, Acc}) ->
            ViewQueryArgs = ViewQueryArgs0#view_query_args{start_key = Key, end_key = Key},
            Options = [{key_group_fun, KeyGroupFun} | couch_set_view_util:make_key_options(ViewQueryArgs)],
            do_fold_reduce(Group, View, FoldFun, Acc, Options)
        end,
        {ok, FoldAcc},
        Keys),
    {ok, FinalAcc}.


do_fold_reduce(Group, ViewInfo, Fun, Acc, Options0) ->
    {reduce, NthRed, View} = ViewInfo,
    #set_view{btree = Bt, reduce_funs = RedFuns} = View,
    Options = case (?set_pbitmask(Group) bor ?set_cbitmask(Group)) of
    0 ->
        Options0;
    _ ->
        ExcludeBitmask = ?set_pbitmask(Group) bor ?set_cbitmask(Group),
        FilterFun = fun(value, {_K, {PartId, _}}) ->
            ((1 bsl PartId) band ?set_abitmask(Group)) =/= 0;
        (branch, {_, _, PartsBitmap}) ->
            case PartsBitmap band ExcludeBitmask of
            0 ->
                all;
            PartsBitmap ->
                none;
            _ ->
                partial
            end
        end,
        lists:keystore(filter_fun, 1, Options0, {filter_fun, FilterFun})
    end,
    PreResultPadding = lists:duplicate(NthRed - 1, []),
    PostResultPadding = lists:duplicate(length(RedFuns) - NthRed, []),
    couch_set_view_mapreduce:start_reduce_context(View),
    ReduceFun =
        fun(reduce, KVs) ->
            KVs2 = couch_set_view_util:expand_dups(KVs, []),
            {ok, Reduced} = couch_set_view_mapreduce:reduce(View, NthRed, KVs2),
            {0, PreResultPadding ++ Reduced ++ PostResultPadding, 0};
        (rereduce, Reds) ->
            UserReds = lists:map(
                fun({_, UserRedsList, _}) -> [lists:nth(NthRed, UserRedsList)] end,
                Reds),
            {ok, Reduced} = couch_set_view_mapreduce:rereduce(View, NthRed, UserReds),
            {0, PreResultPadding ++ Reduced ++ PostResultPadding, 0}
        end,
    WrapperFun = fun({GroupedKey, _}, PartialReds, Acc0) ->
            {_, Reds, _} = couch_btree:final_reduce(ReduceFun, PartialReds),
            Fun(GroupedKey, lists:nth(NthRed, Reds), Acc0)
        end,
    couch_set_view_util:open_raw_read_fd(Group),
    try
        couch_btree:fold_reduce(Bt, WrapperFun, Acc, Options)
    after
        couch_set_view_util:close_raw_read_fd(Group),
        couch_set_view_mapreduce:end_reduce_context(View)
    end.


get_key_pos(_Key, [], _N) ->
    0;
get_key_pos(Key, [{Key1,_Value}|_], N) when Key == Key1 ->
    N + 1;
get_key_pos(Key, [_|Rest], N) ->
    get_key_pos(Key, Rest, N+1).


get_map_view(SetName, DDoc, ViewName, Req) ->
    #set_view_group_req{wanted_partitions = WantedPartitions} = Req,
    {ok, Group0} = get_group(SetName, DDoc, Req),
    {Group, Unindexed} = modify_bitmasks(Group0, WantedPartitions),
    case get_map_view0(ViewName, Group#set_view_group.views) of
    {ok, View} ->
        {ok, View, Group, Unindexed};
    Else ->
        Else
    end.

get_map_view0(_Name, []) ->
    {not_found, missing_named_view};
get_map_view0(Name, [#set_view{map_names=MapNames}=View|Rest]) ->
    case lists:member(Name, MapNames) of
        true -> {ok, View};
        false -> get_map_view0(Name, Rest)
    end.


get_reduce_view(SetName, DDoc, ViewName, Req) ->
    #set_view_group_req{wanted_partitions = WantedPartitions} = Req,
    {ok, Group0} = get_group(SetName, DDoc, Req),
    {Group, Unindexed} = modify_bitmasks(Group0, WantedPartitions),
    #set_view_group{
        views = Views
    } = Group,
    case get_reduce_view0(ViewName, Views) of
    {ok, View} ->
        {ok, View, Group, Unindexed};
    Else ->
        Else
    end.

get_reduce_view0(_Name, []) ->
    {not_found, missing_named_view};
get_reduce_view0(Name, [#set_view{reduce_funs = RedFuns} = View | Rest]) ->
    case get_key_pos(Name, RedFuns, 0) of
        0 -> get_reduce_view0(Name, Rest);
        N -> {ok, {reduce, N, View}}
    end.


reduce_to_count(Reductions) ->
    {Count, _, _} =
    couch_btree:final_reduce(
        fun(reduce, KVs) ->
            Count = lists:sum(
                [case V of {_PartId, {dups, Vals}} -> length(Vals); _ -> 1 end
                || {_, V} <- KVs]),
            {Count, [], 0};
        (rereduce, Reds) ->
            Count = lists:foldl(fun({C, _, _}, Acc) -> Acc + C end, 0, Reds),
            {Count, [], 0}
        end, Reductions),
    Count.


-spec fold(#set_view_group{},
           #set_view{},
           set_view_fold_fun(),
           term(),
           #view_query_args{}) -> {'ok', term(), term()}.
fold(#set_view_group{replica_group = #set_view_group{} = RepGroup} = Group, View, Fun, Acc, ViewQueryArgs) ->
    RepView = lists:nth(View#set_view.id_num + 1, RepGroup#set_view_group.views),
    ViewSpecs = [
        #set_view_spec{
            name = Group#set_view_group.set_name,
            ddoc_id = Group#set_view_group.name,
            view_name = ViewQueryArgs#view_query_args.view_name,
            partitions = [],  % not needed in this context
            group = Group#set_view_group{replica_group = nil},
            view = View
        },
        #set_view_spec{
            name = RepGroup#set_view_group.set_name,
            ddoc_id = RepGroup#set_view_group.name,
            view_name = ViewQueryArgs#view_query_args.view_name,
            partitions = [],  % not needed in this context
            group = RepGroup,
            view = RepView
        }
    ],
    MergeParams = #index_merge{
        indexes = ViewSpecs,
        callback = fun map_view_merge_callback/2,
        user_acc = #merge_acc{fold_fun = Fun, acc = Acc},
        user_ctx = #user_ctx{roles = [<<"_admin">>]},
        % FoldFun does include_docs=true logic
        http_params = ViewQueryArgs#view_query_args{include_docs = false},
        extra = #view_merge{
            keys = ViewQueryArgs#view_query_args.keys,
            make_row_fun = fun(RowData) -> RowData end
        }
    },
    #merge_acc{acc = FinalAcc} = couch_index_merger:query_index(couch_view_merger, MergeParams),
    {ok, nil, FinalAcc};

fold(Group, View, Fun, Acc, #view_query_args{keys = nil} = ViewQueryArgs) ->
    Options = couch_set_view_util:make_key_options(ViewQueryArgs),
    do_fold(Group, View, Fun, Acc, Options);

fold(Group, View, Fun, Acc, #view_query_args{keys = Keys} = ViewQueryArgs0) ->
    lists:foldl(
        fun(Key, {ok, _, FoldAcc}) ->
            ViewQueryArgs = ViewQueryArgs0#view_query_args{start_key = Key, end_key = Key},
            Options = couch_set_view_util:make_key_options(ViewQueryArgs),
            do_fold(Group, View, Fun, FoldAcc, Options)
        end,
        {ok, {[], []}, Acc},
        Keys).


do_fold(Group, #set_view{btree=Btree}, Fun, Acc, Options) ->
    WrapperFun = case ?set_pbitmask(Group) bor ?set_cbitmask(Group) of
    0 ->
        fun(KV, Reds, Acc2) ->
            ExpandedKVs = couch_set_view_util:expand_dups([KV], []),
            fold_fun(Fun, ExpandedKVs, Reds, Acc2)
        end;
    _ ->
        fun(KV, Reds, Acc2) ->
            ExpandedKVs = couch_set_view_util:expand_dups([KV], ?set_abitmask(Group), []),
            fold_fun(Fun, ExpandedKVs, Reds, Acc2)
        end
    end,
    couch_set_view_util:open_raw_read_fd(Group),
    try
        {ok, _LastReduce, _AccResult} =
            couch_btree:fold(Btree, WrapperFun, Acc, Options)
    after
        couch_set_view_util:close_raw_read_fd(Group)
    end.


fold_fun(_Fun, [], _, Acc) ->
    {ok, Acc};
fold_fun(Fun, [KV|Rest], {KVReds, Reds}, Acc) ->
    case Fun(KV, {KVReds, Reds}, Acc) of
    {ok, Acc2} ->
        fold_fun(Fun, Rest, {[KV|KVReds], Reds}, Acc2);
    {stop, Acc2} ->
        {stop, Acc2}
    end.


init([]) ->
    % read configuration settings and register for configuration changes
    RootDir = couch_config:get("couchdb", "view_index_dir"),
    Self = self(),
    ok = couch_config:register(
        fun("couchdb", "view_index_dir", _NewIndexDir)->
            exit(Self, config_change);
        ("mapreduce", "function_timeout", NewTimeout) ->
            ok = mapreduce:set_timeout(list_to_integer(NewTimeout))
        end),

    ok = mapreduce:set_timeout(list_to_integer(
        couch_config:get("mapreduce", "function_timeout", "10000"))),

    % {SetName, {DDocId, Signature}}
    ets:new(couch_setview_name_to_sig, [bag, protected, named_table]),
    % {{SetName, Signature}, Pid | WaitListPids}
    ets:new(couch_sig_to_setview_pid, [set, protected, named_table, {read_concurrency, true}]),
    % {Pid, {SetName, Sig}}
    ets:new(couch_pid_to_setview_sig, [set, private, named_table]),

    ets:new(
        ?SET_VIEW_STATS_ETS,
        [set, public, named_table, {keypos, #set_view_group_stats.ets_key}]),

    {ok, Notifier} = couch_db_update_notifier:start_link(fun ?MODULE:handle_db_event/1),

    process_flag(trap_exit, true),
    ok = couch_file:init_delete_dir(RootDir),
    {ok, #server{root_dir = RootDir, db_notifier = Notifier}}.


terminate(_Reason, _Srv) ->
    [couch_util:shutdown_sync(Pid) || {Pid, _} <-
            ets:tab2list(couch_pid_to_setview_sig)],
    ok.


handle_call({get_group_server, SetName, Group}, From, Server) ->
    #set_view_group{sig = Sig} = Group,
    case ets:lookup(couch_sig_to_setview_pid, {SetName, Sig}) of
    [] ->
        WaitList = [From],
        _ = spawn_monitor(fun() ->
            exit(new_group(Server#server.root_dir, SetName, Group))
        end),
        ets:insert(couch_sig_to_setview_pid, {{SetName, Sig}, WaitList}),
        {noreply, Server};
    [{_, WaitList}] when is_list(WaitList) ->
        WaitList2 = [From | WaitList],
        ets:insert(couch_sig_to_setview_pid, {{SetName, Sig}, WaitList2}),
        {noreply, Server};
    [{_, ExistingPid}] ->
        {reply, {ok, ExistingPid}, Server}
    end;

handle_call({before_database_delete, DbName}, _From, Server) ->
    #server{root_dir = RootDir} = Server,
    case is_set_db(DbName) of
    false ->
        ok;
    {true, SetName, PartId} ->
        lists:foreach(
            fun({_SetName, {_DDocId, Sig}}) ->
                [{_, Pid}] = ets:lookup(couch_sig_to_setview_pid, {SetName, Sig}),
                % Important: view group processes monitor database processes, and
                % they must be notified that a database is about to be deleted
                % before they receive the monitor DOWN messages, therefore the
                % before_delete event sent by couch_server must be synchronous
                % and happen before it shutdowns the database processes. However
                % we must be sure here that we don't do any synchronous calls to
                % couch_server in order to avoid deadlocks.
                gen_server:cast(Pid, {before_partition_delete, PartId})
            end,
            ets:lookup(couch_setview_name_to_sig, SetName)),
        case PartId of
        master ->
            ?LOG_INFO("Deleting index files for set `~s` because master database"
                      "is about to deleted", [SetName]),
            delete_index_dir(RootDir, SetName);
        _ ->
            ok
        end
    end,
    {reply, ok, Server}.


handle_cast(Msg, Server) ->
    {stop, {unexpected_cast, Msg}, Server}.

new_group(Root, SetName, #set_view_group{name = DDocId, sig = Sig} = Group) ->
    process_flag(trap_exit, true),
    Reply = case (catch couch_set_view_group:start_link({Root, SetName, Group})) of
    {ok, NewPid} ->
        unlink(NewPid),
        {ok, NewPid};
    {error, Reason} ->
        Reason;
    Error ->
        Error
    end,
    {SetName, DDocId, Sig, Reply}.

handle_info({'EXIT', Pid, Reason}, #server{db_notifier = Pid} = Server) ->
    ?LOG_ERROR("Database update notifer died with reason: ~p", [Reason]),
    {stop, Reason, Server};

handle_info({'EXIT', FromPid, Reason}, Server) ->
    case ets:lookup(couch_pid_to_setview_sig, FromPid) of
    [] ->
        if Reason /= normal ->
            % non-updater linked process died, we propagate the error
            ?LOG_ERROR("Exit on non-updater process: ~p", [Reason]),
            exit(Reason);
        true -> ok
        end;
    [{_, {SetName, Sig}}] ->
        Entries = ets:match_object(couch_setview_name_to_sig, {SetName, {'$1', Sig}}),
        lists:foreach(fun({_SetName, {DDocId, _Sig}}) ->
            delete_from_ets(FromPid, SetName, DDocId, Sig)
        end, Entries)
    end,
    {noreply, Server};

handle_info({'DOWN', _MonRef, _, _Pid, {SetName, DDocId, Sig, Reply}}, Server) ->
    Key = {SetName, Sig},
    [{_, WaitList}] = ets:lookup(couch_sig_to_setview_pid, Key),
    lists:foreach(fun(From) -> gen_server:reply(From, Reply) end, WaitList),
    case Reply of
    {ok, NewPid} ->
        true = link(NewPid),
        add_to_ets(NewPid, SetName, DDocId, Sig);
    _ ->
        ets:delete(couch_sig_to_setview_pid, Key)
    end,
    {noreply, Server}.

add_to_ets(Pid, SetName, DDocId, Sig) ->
    true = ets:insert(couch_pid_to_setview_sig, {Pid, {SetName, Sig}}),
    true = ets:insert(couch_sig_to_setview_pid, {{SetName, Sig}, Pid}),
    true = ets:insert(couch_setview_name_to_sig, {SetName, {DDocId, Sig}}).

delete_from_ets(Pid, SetName, DDocId, Sig) ->
    true = ets:delete(couch_pid_to_setview_sig, Pid),
    true = ets:delete(couch_sig_to_setview_pid, {SetName, Sig}),
    true = ets:delete_object(couch_setview_name_to_sig, {SetName, {DDocId, Sig}}),
    true = ets:delete(?SET_VIEW_STATS_ETS, {SetName, DDocId, Sig, main}),
    true = ets:delete(?SET_VIEW_STATS_ETS, {SetName, DDocId, Sig, replica}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


delete_index_dir(RootDir, SetName) ->
    DirName = set_index_dir(RootDir, SetName),
    nuke_dir(RootDir, DirName).

set_index_dir(RootDir, SetName) ->
    filename:join([RootDir, "@indexes", ?b2l(SetName)]).

nuke_dir(RootDelDir, Dir) ->
    case file:list_dir(Dir) of
    {error, enoent} -> ok; % doesn't exist
    {ok, Files} ->
        lists:foreach(
            fun(File)->
                Full = Dir ++ "/" ++ File,
                case couch_file:delete(RootDelDir, Full, false) of
                ok -> ok;
                {error, eperm} ->
                    ok = nuke_dir(RootDelDir, Full)
                end
            end,
            Files),
        ok = file:del_dir(Dir)
    end.


% keys come back in the language of btree - tuples.
less_json_ids({JsonA, IdA}, {JsonB, IdB}) ->
    case couch_ejson_compare:less(JsonA, JsonB) of
    0 ->
        IdA < IdB;
    Result ->
        Result < 0
    end.

less_json(A,B) ->
    couch_ejson_compare:less(A, B) < 0.


modify_bitmasks(Group, []) ->
    {Group, []};

modify_bitmasks(#set_view_group{replica_group = nil} = Group, Partitions) ->
    IndexedBitmask = ?set_abitmask(Group) bor ?set_pbitmask(Group),
    WantedBitmask = couch_set_view_util:build_bitmask(Partitions),
    UnindexedBitmask = WantedBitmask band (bnot IndexedBitmask),
    ABitmask2 = WantedBitmask band IndexedBitmask,
    PBitmask2 = (bnot ABitmask2) band IndexedBitmask,
    Header = (Group#set_view_group.index_header)#set_view_index_header{
        abitmask = ABitmask2 band (bnot ?set_cbitmask(Group)),
        pbitmask = PBitmask2
    },
    Unindexed = couch_set_view_util:decode_bitmask(UnindexedBitmask),
    {Group#set_view_group{index_header = Header}, Unindexed};

modify_bitmasks(#set_view_group{replica_group = RepGroup} = Group, Partitions) ->
    IndexedBitmaskMain = ?set_abitmask(Group) bor ?set_pbitmask(Group),
    IndexedBitmaskRep = ?set_abitmask(RepGroup) bor ?set_pbitmask(RepGroup),
    WantedBitmask = couch_set_view_util:build_bitmask(Partitions),

    UnindexedBitmaskMain = (WantedBitmask band (bnot IndexedBitmaskMain)) band (bnot IndexedBitmaskRep),
    UnindexedBitmaskRep = (WantedBitmask band (bnot IndexedBitmaskRep)) band (bnot IndexedBitmaskMain),

    ABitmaskRep2 = WantedBitmask band IndexedBitmaskRep,
    ABitmaskMain2 = (WantedBitmask band IndexedBitmaskMain) band (bnot ABitmaskRep2),

    PBitmaskMain2 = (bnot ABitmaskMain2) band IndexedBitmaskMain,
    PBitmaskRep2 = (bnot ABitmaskRep2) band IndexedBitmaskRep,

    HeaderMain = (Group#set_view_group.index_header)#set_view_index_header{
        abitmask = ABitmaskMain2 band (bnot ?set_cbitmask(Group)),
        pbitmask = PBitmaskMain2
    },
    HeaderRep = (RepGroup#set_view_group.index_header)#set_view_index_header{
        abitmask = ABitmaskRep2 band (bnot ?set_cbitmask(RepGroup)),
        pbitmask = PBitmaskRep2
    },
    Unindexed = couch_set_view_util:decode_bitmask(UnindexedBitmaskMain bor UnindexedBitmaskRep),
    Group2 = Group#set_view_group{
        index_header = HeaderMain,
        replica_group = RepGroup#set_view_group{index_header = HeaderRep}
    },
    {Group2, Unindexed}.


handle_db_event({before_delete, DbName}) ->
    ok = gen_server:call(?MODULE, {before_database_delete, DbName}, infinity);
handle_db_event({Event, {DbName, DDocId}}) when Event == ddoc_updated; Event == ddoc_deleted ->
    case string:tokens(?b2l(DbName), "/") of
    [SetNameStr, "master"] ->
        SetName = ?l2b(SetNameStr),
        lists:foreach(
            fun({_SetName, {_DDocId, Sig}}) ->
                case ets:lookup(couch_sig_to_setview_pid, {SetName, Sig}) of
                [{_, GroupPid}] ->
                    (catch gen_server:cast(GroupPid, ddoc_updated));
                [] ->
                    ok
                end
            end,
            ets:match_object(couch_setview_name_to_sig, {SetName, {DDocId, '$1'}}));
    _ ->
        ok
    end;
handle_db_event(_) ->
    ok.


map_view_merge_callback(start, Acc) ->
    {ok, Acc};

map_view_merge_callback({start, _}, Acc) ->
    {ok, Acc};

map_view_merge_callback(stop, Acc) ->
    {ok, Acc};

map_view_merge_callback({row, Row}, #merge_acc{fold_fun = Fun, acc = Acc} = Macc) ->
    case Fun(Row, nil, Acc) of
    {ok, Acc2} ->
        {ok, Macc#merge_acc{acc = Acc2}};
    {stop, Acc2} ->
        {stop, Macc#merge_acc{acc = Acc2}}
    end;

map_view_merge_callback({debug_info, _From, _Info}, Acc) ->
    {ok, Acc}.



reduce_view_merge_callback(start, Acc) ->
    {ok, Acc};

reduce_view_merge_callback({start, _}, Acc) ->
    {ok, Acc};

reduce_view_merge_callback(stop, Acc) ->
    {ok, Acc};

reduce_view_merge_callback({row, {Key, Red}}, #merge_acc{fold_fun = Fun, acc = Acc} = Macc) ->
    case Fun(Key, Red, Acc) of
    {ok, Acc2} ->
        {ok, Macc#merge_acc{acc = Acc2}};
    {stop, Acc2} ->
        {stop, Macc#merge_acc{acc = Acc2}}
    end;

reduce_view_merge_callback({debug_info, _From, _Info}, Acc) ->
    {ok, Acc}.


is_set_db(DbName) ->
    case string:tokens(?b2l(DbName), "/") of
    [SetName, "master"] ->
        {true, ?l2b(SetName), master};
    [SetName, Rest] ->
        PartId = (catch list_to_integer(Rest)),
        case is_integer(PartId) of
        true ->
            {true, ?l2b(SetName), PartId};
        false ->
            false
        end;
    _ ->
        false
    end.
