-module(static_sup).

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
      #{start => fun normal_child:start_link/1,
        start_args => [a]},
    b =>
      #{start => fun normal_child:start_link/1,
        start_args => [b]},
    c =>
      #{start => fun normal_child:start_link/1,
        start_args => [c]}}.
