%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher Meiklejohn.  All Rights Reserved.
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
%%

-module(lasp_advertisement_counter_SUITE).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

%% common_test callbacks
-export([%% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-compile([export_all]).

-include("lasp.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-define(EXCHANGE_TIMER, 120).
-define(CT_SLAVES, [rita, sue, bob, jerome]).

%% ===================================================================
%% common_test callbacks
%% ===================================================================

init_per_suite(_Config) ->
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(Case, _Config) ->
    ct:pal("Beginning test case ~p", [Case]),

    _Config.

end_per_testcase(Case, _Config) ->
    ct:pal("Ending test case ~p", [Case]),

    _Config.

all() ->
    [
     default_test,
     state_based_with_aae_test,
     state_based_with_aae_and_tree_test,
     delta_based_with_aae_test,
     state_based_ps_with_aae_test,
     state_based_ps_with_aae_and_tree_test,
     delta_based_ps_with_aae_test
    ].

%% ===================================================================
%% tests
%% ===================================================================

-define(AAE_INTERVAL, 10000).
-define(EVAL_NUMBER, 2).
-define(IMPRESSION_NUMBER, 10).
-define(CONVERGENCE_INTERVAL, 10000).

default_test(_Config) ->
    ok.

state_based_with_aae_test(Config) ->
    run(state_based_with_aae_test,
        Config,
        [{mode, state_based},
         {set, orset},
         {broadcast, false},
         {evaluation_identifier, state_based_with_aae}]),
    ok.

state_based_with_aae_and_tree_test(Config) ->
    case os:getenv("OMIT_HIGH_ULIMIT", "false") of
        "false" ->
            run(state_based_with_aae_and_tree_test,
                Config,
                [{mode, state_based},
                 {set, orset},
                 {broadcast, true},
                 {evaluation_identifier, state_based_with_aae_and_tree}]),
            ok;
        _ ->
            %% Omit.
            ok
    end.

delta_based_with_aae_test(Config) ->
    run(delta_based_with_aae_test,
        Config,
        [{mode, delta_based},
         {set, orset},
         {broadcast, false},
         {evaluation_identifier, delta_based_with_aae}]),
    ok.

state_based_ps_with_aae_test(Config) ->
    run(state_based_ps_with_aae_test,
        Config,
        [{mode, state_based},
         {set, awset_ps},
         {broadcast, false},
         {evaluation_identifier, state_based_ps_with_aae}]),
    ok.

state_based_ps_with_aae_and_tree_test(Config) ->
    case os:getenv("OMIT_HIGH_ULIMIT", "false") of
        "false" ->
            run(state_based_ps_with_aae_and_tree_test,
                Config,
                [{mode, state_based},
                 {set, awset_ps},
                 {broadcast, true},
                 {evaluation_identifier, state_based_ps_with_aae_and_tree}]),
            ok;
        _ ->
            %% Omit.
            ok
    end.

delta_based_ps_with_aae_test(Config) ->
    run(delta_based_ps_with_aae_test,
        Config,
        [{mode, delta_based},
         {set, awset_ps},
         {broadcast, false},
         {evaluation_identifier, delta_based_ps_with_aae}]),
    ok.

%% ===================================================================
%% Internal functions
%% ===================================================================

run(Case, Config, Options) ->
    lists:foreach(
        fun(_EvalNumber) ->
            Nodes = start(
              Case,
              Config,
              [{evaluation_timestamp, timestamp()} | Options]
            ),
            wait_for_completion(Nodes),
            stop(Nodes)
        end,
        lists:seq(1, ?EVAL_NUMBER)
    ).

%% @private
start(_Case, _Config, Options) ->
    %% Launch distribution for the test runner.
    ct:pal("Launching Erlang distribution..."),

    os:cmd(os:find_executable("epmd") ++ " -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@" ++ Hostname), shortnames]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end,

    %% Load sasl.
    application:load(sasl),
    ok = application:set_env(sasl,
                             sasl_error_logger,
                             false),
    application:start(sasl),

    %% Load lager.
    {ok, _} = application:ensure_all_started(lager),

    %% Start all three nodes.
    InitializerFun = fun(Name) ->
                            ct:pal("Starting node: ~p", [Name]),

                            NodeConfig = [{monitor_master, true},
                                          {startup_functions, [{code, set_path, [codepath()]}]}],

                            case ct_slave:start(Name, NodeConfig) of
                                {ok, Node} ->
                                    Node;
                                Error ->
                                    ct:fail(Error)
                            end
                     end,
    [First|_] = Nodes = lists:map(InitializerFun, ?CT_SLAVES),

    %% Load Lasp on all of the nodes.
    LoaderFun = fun(Node) ->
                            ct:pal("Loading lasp on node: ~p", [Node]),

                            PrivDir = code:priv_dir(?APP),
                            NodeDir = filename:join([PrivDir, "lager", Node]),

                            %% Manually force sasl loading, and disable the logger.
                            ok = rpc:call(Node, application, load, [sasl]),
                            ok = rpc:call(Node, application, set_env,
                                          [sasl, sasl_error_logger, false]),
                            ok = rpc:call(Node, application, start, [sasl]),

                            ok = rpc:call(Node, application, load, [plumtree]),
                            ok = rpc:call(Node, application, load, [partisan]),
                            ok = rpc:call(Node, application, load, [lager]),
                            ok = rpc:call(Node, application, load, [lasp]),
                            ok = rpc:call(Node, application, set_env, [sasl,
                                                                       sasl_error_logger,
                                                                       false]),
                            ok = rpc:call(Node, application, set_env, [lasp,
                                                                       instrumentation,
                                                                       false]),
                            ok = rpc:call(Node, application, set_env, [lager,
                                                                       log_root,
                                                                       NodeDir]),
                            ok = rpc:call(Node, application, set_env, [plumtree,
                                                                       plumtree_data_dir,
                                                                       NodeDir]),
                            ok = rpc:call(Node, application, set_env, [plumtree,
                                                                       peer_service,
                                                                       partisan_peer_service]),
                            ok = rpc:call(Node, application, set_env, [plumtree,
                                                                       broadcast_exchange_timer,
                                                                       ?EXCHANGE_TIMER]),
                            ok = rpc:call(Node, application, set_env, [plumtree,
                                                                       broadcast_mods,
                                                                       [lasp_plumtree_broadcast_distribution_backend]]),
                            ok = rpc:call(Node, application, set_env, [lasp,
                                                                       data_root,
                                                                       NodeDir])
                     end,
    lists:map(LoaderFun, Nodes),

    %% Configure Lasp settings.
    ConfigureFun = fun(Node) ->
                        %% Configure timers.
                        ok = rpc:call(Node, lasp_config, set,
                                      [aae_interval, ?AAE_INTERVAL]),

                        %% Configure plumtree AAE interval to be the same.
                        ok = rpc:call(Node, application, set_env,
                                      [broadcast_exchange_timer, ?AAE_INTERVAL]),

                        %% Confgure broadcast
                        ok = rpc:call(Node, lasp_config, set,
                                      [aae_interval, ?AAE_INTERVAL]),

                        %% Configure number of impressions.
                        ok = rpc:call(Node, lasp_config, set,
                                      [simulation_event_number, ?IMPRESSION_NUMBER]),

                        %% Configure who should be the server and who's
                        %% the client.
                        case Node of
                            First ->
                                ok = rpc:call(Node, lasp_config, set,
                                              [ad_counter_simulation_server, true]);
                            _ ->
                                ok = rpc:call(Node, lasp_config, set,
                                              [ad_counter_simulation_client, true])
                        end,

                        %% Configure the operational mode.
                        Mode = proplists:get_value(mode, Options),
                        ok = rpc:call(Node, lasp_config, set, [mode, Mode]),

                        %% Configure broadcast settings.
                        Broadcast = proplists:get_value(broadcast, Options),
                        ok = rpc:call(Node, lasp_config, set,
                                      [broadcast, Broadcast]),

                        %% Configure broadcast settings.
                        Set = proplists:get_value(set, Options),
                        ok = rpc:call(Node, lasp_config, set, [set, Set]),

                        %% Configure evaluation identifier.
                        EvalIdentifier = proplists:get_value(evaluation_identifier, Options),
                        ok = rpc:call(Node, lasp_config, set,
                                      [evaluation_identifier, EvalIdentifier]),

                        %% Configure evaluation timestamp.
                        EvalTimestamp = proplists:get_value(evaluation_timestamp, Options),
                        ok = rpc:call(Node, lasp_config, set,
                                      [evaluation_timestamp, EvalTimestamp]),

                        %% Configure instrumentation.
                        ok = rpc:call(Node, lasp_config, set,
                                      [instrumentation, true])
                   end,
    lists:map(ConfigureFun, Nodes),

    ct:pal("Starting lasp."),

    StartFun = fun(Node) ->
                        %% Start lasp.
                        {ok, _} = rpc:call(Node, application, ensure_all_started, [lasp])
                   end,
    lists:map(StartFun, Nodes),

    ct:pal("Custering nodes..."),
    ClusterFun = fun(Node) ->
                        PeerPort = rpc:call(Node,
                                            partisan_config,
                                            get,
                                            [peer_port, ?PEER_PORT]),
                        ct:pal("Joining node: ~p to ~p at port ~p",
                               [Node, First, PeerPort]),
                        ok = rpc:call(First,
                                      lasp_peer_service,
                                      join,
                                      [{Node, {127, 0, 0, 1}, PeerPort}])
                   end,
    lists:map(ClusterFun, Nodes),

    ct:pal("Lasp fully initialized."),

    Nodes.

%% @private
stop(_Nodes) ->
    StopFun = fun(Node) ->
        case ct_slave:stop(Node) of
            {ok, _} ->
                ok;
            Error ->
                ct:fail(Error)
        end
    end,
    lists:map(StopFun, ?CT_SLAVES),
    ok.

%% @private
wait_for_completion([Server | _] = _Nodes) ->
    case lasp_support:wait_until(fun() ->
                Convergence = rpc:call(Server, lasp_config, get, [convergence, false]),
                ct:pal("Waiting for convergence: ~p", [Convergence]),
                Convergence == true
        end, 60*2, ?CONVERGENCE_INTERVAL) of
        ok ->
            ct:pal("Convergence reached!");
        Error ->
            ct:fail("Convergence not reached: ~p", [Error])
    end.

%% @private
codepath() ->
    lists:filter(fun filelib:is_dir/1, code:get_path()).

%% @private
timestamp() ->
    {Mega, Sec, _Micro} = erlang:timestamp(),
    Mega * 1000000 + Sec.
