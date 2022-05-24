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

-module(couch_prometheus_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    init/1
]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {
        {one_for_one, 5, 10},
        [
            ?CHILD(couch_prometheus_server, worker)
        ] ++ maybe_start_prometheus_http()
    }}.

maybe_start_prometheus_http() ->
    case config:get_boolean("prometheus", "additional_port", false) of
        false -> [];
        true -> [?CHILD(couch_prometheus_http, worker)]
    end.
