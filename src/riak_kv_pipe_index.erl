%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Query indexes stored on the local Riak KV vnode sharing the
%%      same index as the pipe vnode owning this worker.  This is the
%%      same idea as riak_kv_pipe_get, but with the `listkeys'
%%      operation instead of `get'.
%%
%%      Inputs to this worker may be `{Bucket :: binary, Query ::
%%      query()}'.  `Query' may take the form of either `{eq, Index,
%%      Key}' or {range Index, StartKey, EndKey}'.
%%
%%      This fitting also understands cover input, as generated by
%%      `riak_pipe_qcover_fsm'.  When processing cover input, the
%%      `FilterVNodes' parameter is passed along to the KV vnode for
%%      filtering there.  (When not processing cover input, the KV
%%      vnode is passed an empty `FilterVNodes' list.)
%%
%%      The convenience function `queue_existing_pipe/3' can be used
%%      to list the index matches directly into an existing pipe.

-module(riak_kv_pipe_index).
-behaviour(riak_pipe_vnode_worker).

-export([init/2,
         process/3,
         done/1,
         queue_existing_pipe/4]).

-include("riak_kv_vnode.hrl").
-include_lib("riak_pipe/include/riak_pipe.hrl").
-include_lib("riak_pipe/include/riak_pipe_log.hrl").

-record(state, {p :: riak_pipe_vnode:partition(),
                fd :: riak_pipe_fitting:details()}).
-opaque state() :: #state{}.

%% @doc Init just stashes the `Partition' and `FittingDetails' for later.
-spec init(riak_pipe_vnode:partition(), riak_pipe_fitting:details()) ->
         {ok, state()}.
init(Partition, FittingDetails) ->
    {ok, #state{p=Partition, fd=FittingDetails}}.

%% @doc Process queries indexes on the KV vnode, according to the
%% input bucket and query.
-spec process(term(), boolean(), state()) -> {ok, state()}.
process(Input, _Last, #state{p=Partition, fd=FittingDetails}=State) ->
    case Input of
        {cover, FilterVNodes, {Bucket, Query}} ->
            ok;
        {Bucket, Query} ->
            FilterVNodes = []
    end,
    ReqId = erlang:phash2(erlang:now()), % stolen from riak_client
    riak_core_vnode_master:coverage(
      ?KV_INDEX_REQ{bucket=Bucket,
                    item_filter=none, %% riak_client uses nothing else?
                    qry=Query},
      {Partition, node()},
      FilterVNodes,
      {raw, ReqId, self()},
      riak_kv_vnode_master),
    keysend_loop(ReqId, Partition, FittingDetails),
    {ok, State}.

keysend_loop(ReqId, Partition, FittingDetails) ->
    receive
        {ReqId, {Bucket, Keys}} ->
            keysend(Bucket, Keys, Partition, FittingDetails),
            keysend_loop(ReqId, Partition, FittingDetails);
        {ReqId, done} ->
            ok
    end.

keysend(Bucket, Keys, Partition, FittingDetails) ->
    [ riak_pipe_vnode_worker:send_output(
         {Bucket, Key}, Partition, FittingDetails)
      || Key <- Keys ],
    ok.

%% @doc Unused.
-spec done(state()) -> ok.
done(_State) ->
    ok.

%% Convenience

-type bucket_or_filter() :: binary() | {binary(), list()}.

%% @doc Query and index, and send the results as inputs to the
%%      given pipe.  This starts a new pipe with one fitting
%%      (`riak_kv_pipe_index'), with its sink pointed at the
%%      destination pipe.  The `riak_pipe_qcover_fsm' module is used
%%      to trigger querying on the appropriate vnodes.  The `eoi'
%%      message is sent to the pipe as soon as it is confirmed that
%%      all querying processes have started.
-spec queue_existing_pipe(riak_pipe:pipe(),
                          bucket_or_filter(),
                          {eq, Index::binary(), Value::term()}
                          |{range, Index::binary(),
                            Start::term(), End::term()},
                          timeout()) ->
         ok | {error, Reason :: term()}.
queue_existing_pipe(Pipe, Bucket, Query, Timeout) ->
    %% make our tiny pipe
    [{_Name, Head}|_] = Pipe#pipe.fittings,
    {ok, LKP} = riak_pipe:exec([#fitting_spec{name=index,
                                              module=?MODULE,
                                              nval=1}],
                               [{sink, Head}]),

    %% setup the cover operation
    ReqId = erlang:phash2(erlang:now()), %% stolen from riak_client
    BucketProps = riak_core_bucket:get_bucket(Bucket),
    NVal = proplists:get_value(n_val, BucketProps),
    {ok, Sender} = riak_pipe_qcover_sup:start_qcover_fsm(
                     [{raw, ReqId, self()},
                      [LKP, {Bucket, Query}, NVal]]),

    %% wait for cover to hit everything
    erlang:link(Sender),
    receive
        {ReqId, done} ->
            %% this eoi will flow into the other pipe
            riak_pipe:eoi(LKP),
            ok;
        {ReqId, Error} ->
            %% this destroy should not harm the other pipe
            riak_pipe:destroy(LKP),
            Error
    after Timeout ->
            %% this destroy should not harm the other pipe
            riak_pipe:destroy(LKP),
            {error, timeout}
    end.
