-module(init_error_sup).

-behaviour(sup).

-export([start_link/0, stop/0]).
-export([children/0]).

-spec start_link() -> et_gen_server:start_ret().
start_link() ->
  sup:start_link({local, ?MODULE}, ?MODULE, #{}).

-spec stop() -> ok.
stop() ->
  sup:stop(?MODULE).

-spec children() -> sup:child_specs().
children() ->
  #{a =>
      #{start => fun test_child:start_link/2,
        start_args => [a, #{}]},
    b =>
      #{start => fun test_child:start_link/2,
        start_args => [b, #{init_error => {error, e1}}]}}.
