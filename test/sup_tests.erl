-module(sup_tests).

-include_lib("eunit/include/eunit.hrl").

static_children_test() ->
  {ok, Sup} = static_sup:start_link(),
  Children = sup:children(Sup),
  ?assertMatch(#{a := {running, _},
                 b := {running, _},
                 c := {running, _}},
               Children),
  Pids = [Pid || {running, Pid} <- maps:values(Children)],
  ?assert(lists:all(fun erlang:is_process_alive/1, Pids)),
  static_sup:stop(),
  ?assertNot(lists:any(fun erlang:is_process_alive/1, Pids)).

init_error_test() ->
  process_flag(trap_exit, true),
  ?assertMatch({error, {start_child, b, _}}, init_error_sup:start_link()),
  ?assertEqual(undefined, erlang:whereis(a)),
  ?assertEqual(undefined, erlang:whereis(b)).

init_exception_test() ->
  process_flag(trap_exit, true),
  ?assertMatch({error, {start_child, b, _}}, init_exception_sup:start_link()),
  ?assertEqual(undefined, erlang:whereis(a)),
  ?assertEqual(undefined, erlang:whereis(b)).

dynamic_child_test() ->
  {ok, Sup} = static_sup:start_link(),
  {ok, D} = sup:start_child(Sup, d1, #{start => fun test_child:start_link/2,
                                        start_args => [d1, #{}]}),
  ?assert(erlang:is_process_alive(D)),
  static_sup:stop(),
  ?assertNot(erlang:is_process_alive(D)).

dynamic_init_error_test() ->
  {ok, Sup} = static_sup:start_link(),
  ?assertMatch({error, e1},
               sup:start_child(Sup, d1,
                               #{start => fun test_child:start_link/2,
                                 start_args => [d1, #{init_error => e1}]})),
  static_sup:stop().

dynamic_init_exception_test() ->
  {ok, Sup} = static_sup:start_link(),
  ?assertMatch({error, {e1, _Trace}},
               sup:start_child(Sup, d1,
                               #{start => fun test_child:start_link/2,
                                 start_args =>
                                   [d1, #{init_exception => {error, e1}}]})),
  static_sup:stop().

dynamic_child_only_test() ->
  {ok, Sup} = empty_sup:start_link(),
  {ok, D} = sup:start_child(Sup, d1, #{start => fun test_child:start_link/2,
                                       start_args => [d1, #{}],
                                       stop => fun test_child:stop/2}),
  ?assert(erlang:is_process_alive(D)),
  Mon = erlang:monitor(process, D),
  ?assertEqual(ok, sup:stop_child(Sup, d1)),
  receive
    {'DOWN', Mon, _, _, Info} ->
      ?assertEqual(normal, Info)
  after 250 ->
      error(monitor_timeout)
  end,
  ?assertNot(erlang:is_process_alive(D)),
  empty_sup:stop().

dynamic_transient_child_only_test() ->
  {ok, Sup} = empty_sup:start_link(),
  {ok, D} = sup:start_child(Sup, d1, #{start => fun test_child:start_link/2,
                                       start_args => [d1, #{}],
                                       stop => fun test_child:stop/2,
                                       transient => true}),
  ?assert(erlang:is_process_alive(D)),
  Mon = erlang:monitor(process, D),
  ?assertEqual(ok, sup:stop_child(Sup, d1)),
  receive
    {'DOWN', Mon, _, _, Info} ->
      ?assertEqual(normal, Info)
  after 250 ->
      error(monitor_timeout)
  end,
  ?assertNot(erlang:is_process_alive(D)),
  empty_sup:stop().
