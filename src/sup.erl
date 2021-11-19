-module(sup).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([start_link/2, start_link/3, stop/1,
         start_child/3, stop_child/2, children/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([options/0, error_reason/0, child_id/0, child_spec/0,
              child_specs/0, start_fun/0, stop_fun/0]).

-type options() ::
        #{stop_timeout => pos_integer()}.

-type error_reason() ::
        {duplicate_child_id, child_id()}
      | {unknown_child_id, child_id()}
      | {start_child, child_id(), term()}
      | {child_already_stopping, child_id()}.

-type state() ::
        #{module := module(),
          options := options(),
          children_ids := #{pid() := child_id()},
          children := #{child_id() := child()}}.

-type child_id() :: term().

-type child_spec() ::
        #{start := start_fun(),
          start_args => [term()],
          stop => stop_fun(),
          transient => boolean()}.

-type child_specs() ::
        #{child_id() := child_spec()}.

-type start_fun() ::
        fun((...) -> {ok, pid()} | {error, term()}).

-type stop_fun() ::
        fun((pid(), term()) -> ok).

-type child() ::
        #{spec := child_spec(),
          pid => pid(),
          stop_timer => reference(),
          restart_timer => reference(),
          backoff => backoff:backoff()}.

-callback children() -> child_specs().

-spec start_link(module(), options()) -> et_gen_server:start_ret().
start_link(Module, Options) ->
  gen_server:start_link(?MODULE, [Module, Options], []).

-spec start_link(et_gen_server:name(), module(), options()) ->
        et_gen_server:start_ret().
start_link(Name, Module, Options) ->
  gen_server:start_link(Name, ?MODULE, [Module, Options], []).

-spec stop(et_gen_server:ref()) -> ok.
stop(Ref) ->
  gen_server:stop(Ref).

-spec start_child(et_gen_server:ref(), child_id(), child_spec()) ->
        {ok, pid()} | {error, error_reason()}.
start_child(Ref, Id, Spec) ->
  call(Ref, {start_child, Id, Spec}).

-spec stop_child(et_gen_server:ref(), child_id()) -> ok.
stop_child(Ref, Id) ->
  call(Ref, {stop_child, Id}).

-spec children(et_gen_server:ref()) -> #{child_id() := pid()}.
children(Ref) ->
  call(Ref, children).

-spec call(et_gen_server:ref(), term()) -> term().
call(Ref, Message) ->
  gen_server:call(Ref, Message, infinity).

-spec init(list()) -> et_gen_server:init_ret(state()).
init([Module, Options]) ->
  logger:update_process_metadata(#{domain => [sup]}),
  ?LOG_DEBUG("starting (module: ~p)", [Module]),
  process_flag(trap_exit, true),
  State = #{module => Module,
            options => Options,
            children_ids => #{},
            children => #{}},
  Specs = maps:to_list(Module:children()),
  start_children(Specs, State).

-spec terminate(et_gen_server:terminate_reason(), state()) -> ok.
terminate(Reason, State) ->
  ?LOG_DEBUG("terminating (reason: ~0tp)", [Reason]),
  stop_children(State).

-spec handle_call(term(), {pid(), et_gen_server:request_id()}, state()) ->
        et_gen_server:handle_call_ret(state()).
handle_call({start_child, Id, Spec}, _From, State) ->
  case do_start_child(Id, Spec, State) of
    {ok, #{pid := Pid}, State2} ->
      {reply, {ok, Pid}, State2};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call({stop_child, Id}, _From, State) ->
  case do_stop_child(Id, normal, State) of
    {ok, State2} ->
      {reply, ok, State2};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call(children, _From, State = #{children := Children}) ->
  ChildrenData = maps:fold(fun (Id, #{pid := Pid}, Acc) ->
                               Acc#{Id => Pid}
                           end, #{}, Children),
  {reply, ChildrenData, State};
handle_call(Msg, From, State) ->
  ?LOG_WARNING("unhandled call ~p from ~p", [Msg, From]),
  {reply, unhandled, State}.

-spec handle_cast(term(), state()) -> et_gen_server:handle_cast_ret(state()).
handle_cast(Msg, State) ->
  ?LOG_WARNING("unhandled cast ~p", [Msg]),
  {noreply, State}.

-spec handle_info(term(), state()) -> et_gen_server:handle_info_ret(state()).
handle_info({stop_timeout, Id}, State = #{children := Children}) ->
  case maps:find(Id, Children) of
    {ok, Child = #{pid := Pid}} ->
      ?LOG_WARNING("child ~0tp (~p) timed out", [Id, Pid]),
      exit(Pid, kill),
      {noreply, remove_or_restart_child(Id, Child, State)};
    error ->
      {noreply, State}
  end;
handle_info({'EXIT', Pid, Reason}, State = #{children_ids := Ids,
                                             children := Children}) ->
  case maps:find(Pid, Ids) of
    {ok, Id} ->
      case Reason of
        normal ->
          ?LOG_DEBUG("child ~0tp (~p) exited", [Id, Pid]);
        _ ->
          ?LOG_ERROR("child ~0tp (~p) exited: ~tp", [Id, Pid, Reason])
      end,
      Child = maps:get(Id, Children),
      {noreply, remove_or_restart_child(Id, Child, State)};
    error ->
      {noreply, State}
  end;
handle_info({restart_child, Id}, State = #{children := Children}) ->
  %% When stopping a child while it is waiting to be restarted, we cancel the
  %% restart timer. We still have to handle the case where the {restart_child,
  %% _} message was already sent; in that case, we will get here, but there
  %% will be no restart_timer in the child because we removed it in
  %% do_stop_child/3. We just ignore it.
  case maps:find(Id, Children) of
    {ok, Child = #{restart_timer := _}} ->
      case do_restart_child(Id, Child, State) of
        {ok, State2} ->
          {noreply, State2};
        {error, Reason} ->
          ?LOG_ERROR("cannot restart child ~0tp: ~tp", [Id, Reason]),
          {noreply, State}
      end;
    {ok, _Child} ->
      {noreply, State};
    error ->
      {noreply, State}
  end;
handle_info(Msg, State) ->
  ?LOG_WARNING("unhandled info ~p", [Msg]),
  {noreply, State}.

-spec start_children([{child_id(), child_spec()}], state()) ->
        {ok, state()} | {stop, error_reason()}.
start_children([], State) ->
  {ok, State};
start_children([{Id, Spec} | Children], State) ->
  case do_start_child(Id, Spec, State) of
    {ok, _, State2} ->
      start_children(Children, State2);
    {error, Reason} ->
      ?LOG_ERROR("cannot start child ~0tp: ~tp", [Id, Reason]),
      stop_children(State),
      {stop, {start_child, Id, Reason}}
  end.

-spec do_start_child(child_id(), child_spec(), state()) ->
        {ok, child(), state()} | {error, error_reason()}.
do_start_child(Id, _Spec, #{children := Children}) when
    is_map_key(Id, Children) ->
  {error, {duplicate_child_id, Id}};
do_start_child(Id, Spec = #{start := Start}, State) ->
  ?LOG_DEBUG("starting child ~0tp (start: ~0tp)", [Id, Start]),
  Args = maps:get(start_args, Spec, []),
  case erlang:apply(Start, Args) of
    {ok, Pid} ->
      ?LOG_DEBUG("child ~0tp started (pid: ~p)", [Id, Pid]),
      Child = #{spec => Spec, pid => Pid},
      {ok, Child, add_child(Id, Child, State)};
    {error, Reason} ->
      {error, Reason}
  end.

-spec stop_children(state()) -> ok.
stop_children(State = #{children := Children}) ->
  maps:foreach(fun (Id, _) ->
                   do_stop_child(Id, shutdown, State)
               end, Children),
  wait_for_children(State).

-spec wait_for_children(state()) -> ok.
wait_for_children(#{children := Children}) when map_size(Children) == 0 ->
  ok;
wait_for_children(State = #{children_ids := Ids, children := Children}) ->
  receive
    {stop_timeout, Id} ->
      case maps:find(Id, Children) of
        {ok, #{pid := Pid}} ->
          exit(Pid, kill),
          wait_for_children(remove_child(Id, Pid, State));
        error ->
          wait_for_children(State)
      end;
    {'EXIT', Pid, _} ->
      case maps:find(Pid, Ids) of
        {ok, Id} ->
          wait_for_children(remove_child(Id, Pid, State));
        error ->
          wait_for_children(State)
      end
  end.

-spec do_stop_child(child_id(), term(), state()) ->
        {ok, state()} | {error, error_reason()}.
do_stop_child(Id, Reason, State = #{children := Children}) ->
  case maps:find(Id, Children) of
    {ok, #{stop_timer := _}} ->
      {error, {child_already_stopping, Id}};
    {ok, Child = #{restart_timer := Timer}} ->
      erlang:cancel_timer(Timer),
      Child2 = maps:without([restart_timer, backoff], Child),
      {ok, State#{children => Children#{Id => Child2}}};
    {ok, Child} ->
      ?LOG_DEBUG("stopping child ~0tp", [Id]),
      call_stop(Child, Reason),
      Timeout = stop_timeout(State),
      Timer = erlang:send_after(Timeout, self(), {stop_timeout, Id}),
      Child2 = Child#{stop_timer => Timer},
      {ok, State#{children => Children#{Id => Child2}}};
    error ->
      {error, {unknown_child_id, Id}}
  end.

-spec call_stop(child(), term()) -> ok.
call_stop(#{pid := Pid, spec := #{stop := Stop}}, Reason) ->
  Stop(Pid, Reason);
call_stop(#{pid := Pid}, Reason) ->
  exit(Pid, Reason).

-spec remove_or_restart_child(child_id(), child(), state()) -> state().
remove_or_restart_child(Id, Child = #{spec := Spec, pid := Pid},
                        State = #{children := Children}) ->
  State2 = remove_child(Id, Pid, State),
  case maps:get(transient, Spec, false) of
    true ->
      State2;
    false ->
      Child2 = maps:without([pid, stop_timer, restart_timer, backoff], Child),
      Child3 = schedule_child_restart(Id, Child2),
      State#{children => Children#{Id => Child3}}
  end.

-spec do_restart_child(child_id(), child(), state()) ->
        {ok, state()} | {error, error_reason()}.
do_restart_child(Id, Child = #{spec := (Spec = #{start := Start})},
                 State) ->
  ?LOG_DEBUG("restarting child ~0tp (start: ~0tp)", [Id, Start]),
  Args = maps:get(start_args, Spec, []),
  case erlang:apply(Start, Args) of
    {ok, Pid} ->
      ?LOG_DEBUG("child ~0tp restarted (pid: ~p)", [Id, Pid]),
      Child2 = maps:without([restart_timer, backoff], Child#{pid => Pid}),
      {ok, add_child(Id, Child2, State)};
    {error, Reason} ->
      %% TODO schedule restart (i.e. return state())
      {error, Reason}
  end.

-spec schedule_child_restart(child_id(), child()) -> child().
schedule_child_restart(Id, Child) ->
  Backoff = case maps:find(backoff, Child) of
              {ok, OldBackoff} ->
                backoff:fail(OldBackoff);
              error ->
                backoff:type(backoff:init(1_000, 60_000), jitter)
            end,
  Delay = backoff:get(Backoff),
  ?LOG_DEBUG("restart child ~0tp in ~bms", [Id, Delay]),
  Timer = erlang:send_after(Delay, self(), {restart_child, Id}),
  Child#{restart_timer => Timer,
         backoff => Backoff}.

-spec add_child(child_id(), child(), state()) -> state().
add_child(Id, Child = #{pid := Pid},
          State = #{children_ids := Ids, children := Children}) ->
  State#{children_ids => Ids#{Pid => Id},
         children => Children#{Id => Child}}.

-spec remove_child(child_id(), pid(), state()) -> state().
remove_child(Id, Pid, State = #{children_ids := Ids, children := Children}) ->
  case maps:find(Id, Children) of
    {ok, Child} ->
      case maps:find(stop_timer, Child) of
        {ok, Timer} ->
          erlang:cancel_timer(Timer);
        error ->
          ok
      end,
      State#{children_ids => maps:remove(Pid, Ids),
             children => maps:remove(Id, Children)};
    error ->
      error({unknown_child_id, Id})
  end.

-spec stop_timeout(state()) -> pos_integer().
stop_timeout(#{options := #{stop_timeout := Timeout}}) ->
  Timeout;
stop_timeout(_) ->
  5000.
