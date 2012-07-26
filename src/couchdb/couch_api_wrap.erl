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

-module(couch_api_wrap).

% This module wraps the native erlang API, and allows for performing
% operations on a remote vs. local databases via the same API.
%
% Notes:
% Many options and apis aren't yet supported here, they are added as needed.

-include("couch_db.hrl").
-include("couch_api_wrap.hrl").

-export([
    db_open/2,
    db_open/3,
    db_close/1,
    get_db_info/1,
    update_doc/3,
    update_docs/3,
    update_docs/4,
    ensure_full_commit/1,
    get_missing_revs/2,
    open_doc/3,
    open_doc/5,
    couch_doc_open/3,
    changes_since/5,
    db_uri/1
    ]).

-import(couch_api_wrap_httpc, [
    httpdb_setup/1,
    send_req/3
    ]).

-import(couch_util, [
    encode_doc_id/1,
    get_value/2,
    get_value/3
    ]).


db_uri(#httpdb{url = Url}) ->
    couch_util:url_strip_password(Url);

db_uri(#db{name = Name}) ->
    db_uri(Name);

db_uri(DbName) ->
    ?b2l(DbName).


db_open(Db, Options) ->
    db_open(Db, Options, false).

db_open(#httpdb{} = Db1, _Options, Create) ->
    {ok, Db} = couch_api_wrap_httpc:setup(Db1),
    case Create of
    false ->
        ok;
    true ->
        send_req(Db, [{method, "PUT"}], fun(_, _, _) -> ok end)
    end,
    send_req(Db, [{method, "HEAD"}],
        fun(200, _, _) ->
            {ok, Db};
        (401, _, _) ->
            throw({unauthorized, ?l2b(db_uri(Db))});
        (_, _, _) ->
            throw({db_not_found, ?l2b(db_uri(Db))})
        end);
db_open(DbName, Options, Create) ->
    try
        case Create of
        false ->
            ok;
        true ->
            ok = couch_httpd:verify_is_server_admin(
                get_value(user_ctx, Options)),
            couch_db:create(DbName, Options)
        end,
        case couch_db:open(DbName, Options) of
        {not_found, _Reason} ->
            throw({db_not_found, DbName});
        {ok, _Db} = Success ->
            Success
        end
    catch
    throw:{unauthorized, _} ->
        throw({unauthorized, DbName})
    end.

db_close(#httpdb{} = HttpDb) ->
    ok = couch_api_wrap_httpc:tear_down(HttpDb);
db_close(DbName) ->
    catch couch_db:close(DbName).


get_db_info(#httpdb{} = Db) ->
    send_req(Db, [],
        fun(200, _, {Props}) ->
            {ok, Props}
        end);
get_db_info(#db{name = DbName, user_ctx = UserCtx}) ->
    {ok, Db} = couch_db:open(DbName, [{user_ctx, UserCtx}]),
    {ok, Info} = couch_db:get_db_info(Db),
    couch_db:close(Db),
    {ok, [{couch_util:to_binary(K), V} || {K, V} <- Info]}.


ensure_full_commit(#httpdb{} = Db) ->
    send_req(
        Db,
        [{method, "POST"}, {path, "_ensure_full_commit"},
            {headers, [{"Content-Type", "application/json"}]}],
        fun(201, _, {Props}) ->
            {ok, get_value(<<"instance_start_time">>, Props)};
        (_, _, {Props}) ->
            {error, get_value(<<"error">>, Props)}
        end);
ensure_full_commit(Db) ->
    couch_db:ensure_full_commit(Db).


get_missing_revs(#httpdb{} = Db, IdRevList) ->
    JsonBody = {[{Id, couch_doc:rev_to_str(Rev)} || {Id, Rev} <- IdRevList]},
    send_req(
        Db,
        [{method, "POST"}, {path, "_revs_diff"}, {body, ?JSON_ENCODE(JsonBody)}],
        fun(200, _, {Props}) ->
            ConvertToNativeFun = fun({Id, {Result}}) ->
                MissingRev = couch_doc:parse_rev(
                    get_value(<<"missing">>, Result)
                ),
                {Id, MissingRev}
            end,
            {ok, lists:map(ConvertToNativeFun, Props)}
        end);
get_missing_revs(Db, IdRevList) ->
    couch_db:get_missing_revs(Db, IdRevList).


open_doc(#httpdb{}, _Id, _Options, Fun, Acc) ->
    Fun({error, <<"not_found">>}, Acc);
open_doc(Db, Id, Options, Fun, Acc) ->
    Result = couch_db:open_doc(Db, Id, Options),
    Fun(Result, Acc).


open_doc(#httpdb{} = Db, Id, Options) ->
    send_req(
        Db,
        [{path, encode_doc_id(Id)}],
        fun(200, _, Body) ->
            % If we need the rev, we can get it from the
            % "X-Couchbase-Meta" header.
            BinDoc = couch_doc:from_json_obj({[
                {<<"meta">>, {[{<<"id">>, Id}]}},
                {<<"json">>, Body}]}),

            case lists:member(ejson_body, Options) of
            true ->
                {ok, couch_doc:with_ejson_body(BinDoc)};
            false ->
                {ok, BinDoc}
            end;
        (_, _, {Props}) ->
            {error, get_value(<<"error">>, Props)}
        end);
open_doc(Db, Id, Options) ->
    case couch_db:open_doc(Db, Id, Options) of
    {ok, _} = Ok ->
        Ok;
    {not_found, _Reason} ->
        {error, <<"not_found">>}
    end.


couch_doc_open(Db, DocId, Options) ->
    case open_doc(Db, DocId, Options) of
    {ok, Doc} ->
        Doc;
     Error ->
        throw(Error)
    end.

update_doc(#httpdb{} = Db, #doc{id = <<"_local/", _/binary>>} = Doc, Options) ->
    update_docs(Db, [Doc], Options, interactive_edit);
update_doc(Db, Doc, Options) ->
    couch_db:update_doc(Db, Doc, Options).

update_docs(Db, DocList, Options) ->
    update_docs(Db, DocList, Options, interactive_edit).


update_docs(_, [], _, _) ->
    ok;
update_docs(#httpdb{} = HttpDb, DocList, Options, UpdateType) ->
    Prefix = case UpdateType of
    replicated_changes ->
        <<"{\"new_edits\":false,\"docs\":[">>;
    interactive_edit ->
        <<"{\"docs\":[">>
    end,
    Suffix = <<"]}">>,
    % Note: nginx and other servers don't like PUT/POST requests without
    % a Content-Length header, so we can't do a chunked transfer encoding
    % and JSON encode each doc only before sending it through the socket.
    {Docs, Len} = lists:mapfoldl(
        fun(#doc{} = Doc, Acc) ->
            Json = couch_doc:to_json_bin(Doc),
            {Json, Acc + iolist_size(Json)};
        (Doc, Acc) ->
            {Doc, Acc + iolist_size(Doc)}
        end,
        byte_size(Prefix) + byte_size(Suffix) + length(DocList) - 1,
        DocList),
    Headers = [
        {"Content-Length", integer_to_list(Len)},
        {"Content-Type", "application/json"}
    ],
    ReqOptions = [
        {method, "POST"},
        {path, "_bulk_docs"},
        {headers, maybe_add_delayed_commit(Headers, Options)},
        {lhttpc_options, [{partial_upload, 3}]}
    ],
    SendDocsFun = fun(Data, {SendFun, N}) ->
        {ok, SendFun2} = case N > 1 of
        true ->
            SendFun([Data, <<",">>]);
        false ->
            SendFun(Data)
        end,
        {SendFun2, N - 1}
    end,
    ReqCallback = fun(UploadFun) ->
        {ok, UploadFun2} = UploadFun(Prefix),
        {UploadFun3, 0} = lists:foldl(SendDocsFun, {UploadFun2, length(Docs)}, Docs),
        {ok, UploadFun4} = UploadFun3(Suffix),
        case UploadFun4(eof) of
        {ok, 201, _Headers, _Body} ->
            ok;
        {ok, _Code, _Headers, Error} ->
            {ok, Error}
        end
    end,
    send_req(HttpDb, ReqOptions, ReqCallback);
update_docs(Db, DocList, Options, replicated_changes) ->
    ok = couch_db:update_docs(Db, DocList, Options).


changes_since(#httpdb{headers = Headers1} = HttpDb, Style, StartSeq,
    UserFun, Options) ->
    BaseQArgs = case get_value(continuous, Options, false) of
    false ->
        [{"feed", "normal"}];
    true ->
        [{"feed", "continuous"}, {"heartbeat", "10000"}]
    end ++ [
        {"style", atom_to_list(Style)}, {"since", couch_util:to_list(StartSeq)}
    ],
    DocIds = get_value(doc_ids, Options),
    {QArgs, Method, Body, Headers} = case DocIds of
    undefined ->
        QArgs1 = maybe_add_changes_filter_q_args(BaseQArgs, Options),
        {QArgs1, "GET", [], Headers1};
    _ when is_list(DocIds) ->
        Headers2 = [{"Content-Type", "application/json"} | Headers1],
        JsonDocIds = ?JSON_ENCODE({[{<<"doc_ids">>, DocIds}]}),
        {[{"filter", "_doc_ids"} | BaseQArgs], "POST", JsonDocIds, Headers2}
    end,
    ReqOptions = [
        {method, Method},
        {path, "_changes"},
        {body, Body},
        {headers, Headers},
        {qs, QArgs},
        {lhttpc_options, [{partial_download, [{window_size, 3}]}]}
    ],
    send_req(
        HttpDb,
        ReqOptions,
        fun(200, _, DataStreamFun) ->
                parse_changes_feed(Options, UserFun, DataStreamFun);
            (405, _, _) when is_list(DocIds) ->
                % CouchDB versions < 1.1.0 don't have the builtin _changes feed
                % filter "_doc_ids" neither support POST
                Req2Options = [
                    {method, "GET"},
                    {path, "_changes"},
                    {qs, BaseQArgs},
                    {headers, Headers1},
                    {lhttpc_options, [{partial_download, [{window_size, 3}]}]}
                ],
                send_req(HttpDb, Req2Options,
                    fun(200, _, DataStreamFun2) ->
                        UserFun2 = fun(#doc_info{id = Id} = DocInfo) ->
                            case lists:member(Id, DocIds) of
                            true ->
                                UserFun(DocInfo);
                            false ->
                                ok
                            end
                        end,
                        parse_changes_feed(Options, UserFun2, DataStreamFun2)
                    end)
        end);
changes_since(Db, Style, StartSeq, UserFun, Options) ->
    Filter = case get_value(doc_ids, Options) of
    undefined ->
        ?b2l(get_value(filter, Options, <<>>));
    _DocIds ->
        "_doc_ids"
    end,
    Args = #changes_args{
        style = Style,
        since = StartSeq,
        filter = Filter,
        feed = case get_value(continuous, Options, false) of
            true ->
                "continuous";
            false ->
                "normal"
        end,
        timeout = infinity
    },
    QueryParams = get_value(query_params, Options, {[]}),
    Req = changes_json_req(Db, Filter, QueryParams, Options),
    ChangesFeedFun = couch_changes:handle_changes(Args, {json_req, Req}, Db),
    ChangesFeedFun(fun({change, Change, _}, _) ->
            UserFun(json_to_doc_info(Change));
        (_, _) ->
            ok
    end).


% internal functions

maybe_add_changes_filter_q_args(BaseQS, Options) ->
    case get_value(filter, Options) of
    undefined ->
        BaseQS;
    FilterName ->
        {Params} = get_value(query_params, Options, {[]}),
        [{"filter", ?b2l(FilterName)} | lists:foldl(
            fun({K, V}, QSAcc) ->
                Ks = couch_util:to_list(K),
                case lists:keymember(Ks, 1, QSAcc) of
                true ->
                    QSAcc;
                false ->
                    [{Ks, couch_util:to_list(V)} | QSAcc]
                end
            end,
            BaseQS, Params)]
    end.

parse_changes_feed(Options, UserFun, DataStreamFun) ->
    case get_value(continuous, Options, false) of
    true ->
        continuous_changes(DataStreamFun, UserFun);
    false ->
        EventFun = fun(Ev) ->
            changes_ev1(Ev, fun(DocInfo, _) -> UserFun(DocInfo) end, [])
        end,
        json_stream_parse:events(DataStreamFun, EventFun)
    end.

changes_json_req(_Db, "", _QueryParams, _Options) ->
    {[]};
changes_json_req(_Db, "_doc_ids", _QueryParams, Options) ->
    {[{<<"doc_ids">>, get_value(doc_ids, Options)}]};
changes_json_req(Db, FilterName, {QueryParams}, _Options) ->
    {ok, Info} = couch_db:get_db_info(Db),
    % simulate a request to db_name/_changes
    {[
        {<<"info">>, {Info}},
        {<<"id">>, null},
        {<<"method">>, 'GET'},
        {<<"path">>, [couch_db:name(Db), <<"_changes">>]},
        {<<"query">>, {[{<<"filter">>, FilterName} | QueryParams]}},
        {<<"headers">>, []},
        {<<"json">>, []},
        {<<"peer">>, <<"replicator">>},
        {<<"form">>, []},
        {<<"cookie">>, []},
        {<<"userCtx">>, couch_util:json_user_ctx(Db)}
    ]}.


changes_ev1(object_start, UserFun, UserAcc) ->
    fun(Ev) -> changes_ev2(Ev, UserFun, UserAcc) end.

changes_ev2({key, <<"results">>}, UserFun, UserAcc) ->
    fun(Ev) -> changes_ev3(Ev, UserFun, UserAcc) end;
changes_ev2(_, UserFun, UserAcc) ->
    fun(Ev) -> changes_ev2(Ev, UserFun, UserAcc) end.

changes_ev3(array_start, UserFun, UserAcc) ->
    fun(Ev) -> changes_ev_loop(Ev, UserFun, UserAcc) end.

changes_ev_loop(object_start, UserFun, UserAcc) ->
    fun(Ev) ->
        json_stream_parse:collect_object(Ev,
            fun(Obj) ->
                UserAcc2 = UserFun(json_to_doc_info(Obj), UserAcc),
                fun(Ev2) -> changes_ev_loop(Ev2, UserFun, UserAcc2) end
            end)
    end;
changes_ev_loop(array_end, _UserFun, _UserAcc) ->
    fun(_Ev) -> changes_ev_done() end.

changes_ev_done() ->
    fun(_Ev) -> changes_ev_done() end.

continuous_changes(DataFun, UserFun) ->
    {DataFun2, _, Rest} = json_stream_parse:events(
        DataFun,
        fun(Ev) -> parse_changes_line(Ev, UserFun) end),
    continuous_changes(fun() -> {Rest, DataFun2} end, UserFun).

parse_changes_line(object_start, UserFun) ->
    fun(Ev) ->
        json_stream_parse:collect_object(Ev,
            fun(Obj) -> UserFun(json_to_doc_info(Obj)) end)
    end.

json_to_doc_info({Props}) ->
    {Change} = get_value(<<"changes">>, Props),
    Rev = couch_doc:parse_rev(get_value(<<"rev">>, Change)),
    Del = (true =:= get_value(<<"deleted">>, Change)),
    #doc_info{
        id = get_value(<<"id">>, Props),
        local_seq = get_value(<<"seq">>, Props),
        rev = Rev,
        deleted = Del
    }.

maybe_add_delayed_commit(Headers, Options) ->
    case lists:member(delay_commit, Options) of
    true ->
        [{"X-Couch-Full-Commit", "false"} | Headers];
    false ->
        Headers
    end.

