%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(capi_spatial).

-include("couch_db.hrl").
-include("couch_index_merger.hrl").
-include("ns_common.hrl").

-export([handle_spatial_req/3]).

-define(RETRY_INTERVAL, 5 * 1000).
-define(RETRY_ATTEMPTS, 20).

design_doc_spatial(Req, #db{name=BucketName} = Db, DesignName, SpatialName,
        VBuckets) ->
    DDocId = <<"_design/", DesignName/binary>>,
    Specs = capi_view:build_local_simple_specs(BucketName, DDocId, SpatialName,
        VBuckets),
    MergeParams = spatial_merge_params(Req, Db, DDocId, SpatialName, Specs),
    couch_index_merger:query_index(couch_spatial_merger, Req, MergeParams).

design_doc_spatial(Req, Db, DesignName, SpatialName) ->
    DDocId = <<"_design/", DesignName/binary>>,
    design_doc_spatial_loop(Req, Db, DDocId, SpatialName, ?RETRY_ATTEMPTS).

design_doc_spatial_loop(_Req, _Db, _DDocId, _SpatialName, 0) ->
    throw({error, inconsistent_state});
design_doc_spatial_loop(Req, Db, DDocId, SpatialName, Attempt) ->
    MergeParams = spatial_merge_params(Req, Db, DDocId, SpatialName),
    try
        couch_index_merger:query_index(couch_spatial_merger, Req, MergeParams)
    catch
        % Spatial indexes don't supprt set views at the moment, though keeping
        % the code here for future reference doesn't do any harm.
        throw:{error, set_view_outdated} ->
            ?log_debug("Got `set_view_outdated` error. Retrying."),
            timer:sleep(?RETRY_INTERVAL),
            design_doc_spatial_loop(Req, Db, DDocId, SpatialName, Attempt - 1)
    end.

handle_spatial_req(Req, Db, DDoc) when Db#db.filepath =/= undefined ->
    couch_httpd_spatial:handle_spatial_req(Req, Db, DDoc);

handle_spatial_req(#httpd{method='GET',
        path_parts=[_, _, DName, _, SpatialName]}=Req, #db{name=Name} = Db,
        _DDoc) ->
    case capi_view:run_on_subset(Req, Name) of
    full_set ->
        design_doc_spatial(Req, Db, DName, SpatialName);
    VBucket ->
        design_doc_spatial(Req, Db, DName, SpatialName, [VBucket])
    end;

handle_spatial_req(#httpd{method='POST',
        path_parts=[_, _, DName, _, SpatialName]}=Req, Db, _DDoc) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    design_doc_spatial(Req, Db, DName, SpatialName);

handle_spatial_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST,HEAD").


spatial_merge_params(Req, #db{name = BucketName} = Db, DDocId, SpatialName) ->
    NodeToVBuckets = capi_view:node_vbuckets_dict(?b2l(BucketName)),
    Config = ns_config:get(),
    %% FullSpatialName = case DDocId of
    %% nil ->
    %%     % _all_docs and other special builtin views
    %%     SpatialName;
    %% _ ->
    %%     iolist_to_binary([BucketName, "%2F", "master", $/, DDocId, $/,
    %%         SpatialName])
    %% end,
    FullSpatialName = iolist_to_binary([BucketName, "%2F", "master", $/, DDocId, $/,
        SpatialName]),
    SpatialSpecs = dict:fold(
        fun(Node, VBuckets, Acc) when Node =:= node() ->
            capi_view:build_local_simple_specs(BucketName, DDocId, SpatialName,
                VBuckets) ++ Acc;
        (Node, VBuckets, Acc) ->
           [build_remote_specs(
               Node, BucketName, FullSpatialName, VBuckets, Config) | Acc]
        end, [], NodeToVBuckets),
    spatial_merge_params(Req, Db, DDocId, SpatialName, SpatialSpecs).

spatial_merge_params(Req, _Db, _DDocId, _SpatialName, SpatialSpecs) ->
    case Req#httpd.method of
    'GET' ->
        Body = [];
    'POST' ->
        {Body} = couch_httpd:json_body_obj(Req)
    end,
    MergeParams0 = #index_merge{
        indexes = SpatialSpecs
    },
    % XXX vmx 20110816: couch_httpd_view_merger:apply_http_config/3 should
    %     perhaps be moved into a utils module
    couch_httpd_view_merger:apply_http_config(Req, Body, MergeParams0).

build_remote_specs(Node, BucketName, FullViewName, VBuckets, Config) ->
    MergeURL = iolist_to_binary(capi_utils:capi_url(Node, "/_spatial_merge",
        "127.0.0.1", Config)),
    Props = {[
        {<<"spatial">>,
            {[{capi_view:vbucket_db_name(BucketName, VBId), FullViewName} ||
                VBId <- VBuckets]}}
    ]},
    #merged_index_spec{url = MergeURL, ejson_spec = Props}.