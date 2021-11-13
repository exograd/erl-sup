-module(sup_tests).

-include_lib("eunit/include/eunit.hrl").

static_children_test() ->
  {ok, Sup} = static_sup:start_link(),
  Children = sup:children(Sup),
  ?assertMatch(#{a := _, b := _, c := _}, Children),
  ?assert(lists:all(fun erlang:is_process_alive/1, maps:values(Children))),
  static_sup:stop(),
  ?assertNot(lists:any(fun erlang:is_process_alive/1, maps:values(Children))).

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
