-module(normal_child).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).

-type state() ::
        #{name := atom()}.

-spec start_link(atom()) -> et_gen_server:start_ret().
start_link(Name) ->
  gen_server:start_link(?MODULE, [Name], []).

-spec init(list()) -> et_gen_server:init_ret(state()).
init([Name]) ->
  ?LOG_INFO("starting ~p", [Name]),
  {ok, #{name => Name}}.

-spec terminate(et_gen_server:terminate_reason(), state()) -> ok.
terminate(_Reason, _State) ->
  ok.

-spec handle_call(term(), {pid(), et_gen_server:request_id()}, state()) ->
        et_gen_server:handle_call_ret(state()).
handle_call(Msg, From, State) ->
  ?LOG_WARNING("unhandled call ~p from ~p", [Msg, From]),
  {reply, unhandled, State}.

-spec handle_cast(term(), state()) -> et_gen_server:handle_cast_ret(state()).
handle_cast(Msg, State) ->
  ?LOG_WARNING("unhandled cast ~p", [Msg]),
  {noreply, State}.

-spec handle_info(term(), state()) -> et_gen_server:handle_info_ret(state()).
handle_info(Msg, State) ->
  ?LOG_WARNING("unhandled info ~p", [Msg]),
  {noreply, State}.
