-module(sup_tests).

-include_lib("eunit/include/eunit.hrl").

static_children_test() ->
  {ok, Sup} = static_sup:start_link(),
  Children = sup:children(Sup),
  ?assertMatch(#{a := _, b := _, c := _}, Children),
  ?assert(lists:all(fun erlang:is_process_alive/1, maps:values(Children))),
  static_sup:stop(),
  ?assertNot(lists:any(fun erlang:is_process_alive/1, maps:values(Children))).
