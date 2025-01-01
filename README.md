# Erlang Websocket Client

[![Build Status](https://travis-ci.org/sanmiguel/websocket_client.svg?branch=master)](https://travis-ci.org/sanmiguel/websocket_client)

[![Coverage Status](https://coveralls.io/repos/github/sanmiguel/websocket_client/badge.svg?branch=master)](https://coveralls.io/github/sanmiguel/websocket_client?branch=master)

## Existing features

1. Client to Server Masking
2. OTP compliant
3. Callback-driven behaviour
3. Handshake validation
4. TCP and SSL support
5. Handling of text, binary, ping, pong, and close frames
6. Handling of continuation frames
7. Automated ping/pong and keepalive

## Usage

For basic usage, see `examples/sample_ws_handler.erl`:

```erlang
-module(sample_ws_handler).

-behaviour(websocket_client).

-export([
         start_link/0,
         init/1,
         onconnect/2,
         ondisconnect/2,
         websocket_handle/3,
         websocket_info/3,
         websocket_terminate/3
        ]).

start_link() ->
    crypto:start(),
    ssl:start(),
    websocket_client:start_link("wss://echo.websocket.org", ?MODULE, []).

init([]) ->
    {once, 2}.

onconnect(_WSReq, State) ->
    websocket_client:cast(self(), {text, <<"message 1">>}),
    {ok, State}.

ondisconnect({remote, closed}, State) ->
    {reconnect, State}.

websocket_handle({pong, _}, _ConnState, State) ->
    {ok, State};
websocket_handle({text, Msg}, _ConnState, 5) ->
    io:format("Received msg ~p~n", [Msg]),
    {close, <<>>, "done"};
websocket_handle({text, Msg}, _ConnState, State) ->
    io:format("Received msg ~p~n", [Msg]),
    timer:sleep(1000),
    BinInt = list_to_binary(integer_to_list(State)),
    {reply, {text, <<"hello, this is message #", BinInt/binary >>}, State + 1}.

websocket_info(start, _ConnState, State) ->
    {reply, {text, <<"erlang message received">>}, State}.

websocket_terminate(Reason, _ConnState, State) ->
    io:format("Websocket closed in state ~p with reason ~p~n",
              [State, Reason]),
    ok.
```

The above code will send messages to the echo server that count up
from 1 through 4. It will also print all replies from the server:

```
Received msg <<"this is message 1">>
Received msg <<"hello, this is message #2">>
Received msg <<"hello, this is message #3">>
Received msg <<"hello, this is message #4">>
```

This client implements a cowboy like `websocket_client_handler` to
interact with a websocket server. Currently, it can connect via tcp or
ssl via the `ws` and `wss` protocols. It can also send and receive
contiguous text or binary websocket frames.

## TODO

The client has been significantly reworked, now backed by `gen_statem`. There may still be bugs.
Please report them.

1. Stop using `verify_none` by default
2. Add more complete testing - preferably based on / using Autobahn.
