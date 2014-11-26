-module(ws_client).

-behaviour(websocket_client).

-export([
         start_link/0,
         start_link/1,
         send_text/2,
         send_binary/2,
         send_ping/2,
         sync_send_text/2,
         sync_send_binary/2,
         sync_send_ping/2,
         recv/2,
         recv/1,
         stop/1
        ]).

-export([
         init/1,
         onconnect/2,
         ondisconnect/2,
         websocket_handle/3,
         websocket_info/3,
         websocket_terminate/3
        ]).

-record(state, {
          buffer = [] :: list(),
          waiting = undefined :: undefined | pid()
         }).

start_link() ->
    start_link("ws://localhost:8080").

start_link(Url) ->
    websocket_client:start_link(Url, ?MODULE, [], false).

stop(Pid) ->
    Pid ! stop.

send_text(Pid, Msg) ->
    websocket_client:cast(Pid, {text, Msg}).

send_binary(Pid, Msg) ->
    websocket_client:cast(Pid, {binary, Msg}).

send_ping(Pid, Msg) ->
    websocket_client:cast(Pid, {ping, Msg}).

sync_send_text(Pid, Msg) ->
    websocket_client:send(Pid, {text, Msg}).

sync_send_binary(Pid, Msg) ->
    websocket_client:send(Pid, {binary, Msg}).

sync_send_ping(Pid, Msg) ->
    websocket_client:send(Pid, {ping, Msg}).

recv(Pid) ->
    recv(Pid, 5000).

recv(Pid, Timeout) ->
    Pid ! {recv, self()},
    receive
        M -> M
    after
        Timeout -> error
    end.

init(_) ->
    {ok, #state{}}.

onconnect(_WSReq, State) ->
    {ok, State}.

ondisconnect(Reason, State) ->
    {close, Reason, State}.

websocket_handle(Frame, _, State = #state{waiting = undefined, buffer = Buffer}) ->
    ct:pal("Client added frame ~p to buffer~n", [Frame]),
    {ok, State#state{buffer = Buffer++[Frame]}};
websocket_handle(Frame, _, State = #state{waiting = From}) ->
    ct:pal("Client forwarded frame ~p to ~p ~n", [Frame, From]),
    From ! Frame,
    {ok, State#state{waiting = undefined}}.

websocket_info({recv, From}, _, State = #state{buffer = []}) ->
    {ok, State#state{waiting = From}};
websocket_info({recv, From}, _, State = #state{buffer = [Top|Rest]}) ->
    ct:pal("Receiving from: ~p~n", [From]),
    From ! Top,
    {ok, State#state{buffer = Rest}};
websocket_info(stop, _, State) ->
    {close, <<>>, State}.

websocket_terminate(Close, _, State) ->
    ct:pal("Websocket closed with frame ~p and state ~p", [Close, State]),
    ok.
