-module(echo_server).

% -behaviour(cowboy_websocket_handler).

-export([
         start/0,
         stop/0
        ]).

-export([
         init/2,
         websocket_init/1,
         websocket_handle/2,
         websocket_info/2,
         websocket_terminate/2
        ]).

-record(state, { stopcode, init_text }).

start() ->
    ct:pal("Starting ~p.~n", [?MODULE]),
    Dispatch = cowboy_router:compile([{'_', [
                                             {"/hello", ?MODULE, []},
                                             {'_', ?MODULE, []}
                                            ]}]),
    {ok, _} = cowboy:start_clear(echo_listener,
                                 #{socket_opts => [{nodelay, true}, {port, 8080}],
                                   max_connections => 100},
                                 #{env => #{dispatch => Dispatch}}).

stop() ->
    cowboy:stop_listener(echo_listener).

init(Req, _Opts) ->
    case maps:from_list(cowboy_req:parse_qs(Req)) of
        #{ <<"code">> := Code } ->
            IntegerCode = list_to_integer(binary_to_list(Code)),
            Req2 = cowboy_req:reply(IntegerCode, Req),
            {cowboy_websocket, Req2, #state{ stopcode = IntegerCode }};
        #{ <<"q">> := Text } ->
            {cowboy_websocket, Req, #state{ init_text = Text }};
        _ ->
            {cowboy_websocket, Req, #state{}}
    end.

websocket_init(#state{stopcode = Code}=State) when is_integer(Code) ->
    ct:pal("~p shuting down on init using '~p' status code~n", [?MODULE, Code]),
    {[{shutdown_reason, "Code"}], State};
websocket_init(#state{init_text = Text}=State) when is_binary(Text) ->
    {[{text, Text}], State};
websocket_init(State) ->
    {[], State}.

websocket_handle({ping, Payload}=_Frame, State) ->
    ct:pal("~p pingpong with size ~p~n", [?MODULE, byte_size(Payload)]),
    {ok, State};
websocket_handle({Type, Payload}=Frame, State) ->
    ct:pal("~p replying with ~p of size ~p~n", [?MODULE, Type, byte_size(Payload)]),
    {reply, Frame, State}.

websocket_info({send, Text}, State) ->
    timer:sleep(1),
    ct:pal("~p sent frame of size ~p ~n", [?MODULE, byte_size(Text)]),
    {reply, {text, Text}, State};

websocket_info(_Msg, State) ->
    ct:pal("~p received OoB msg: ~p~n", [?MODULE, _Msg]),
    {ok, State}.

websocket_terminate(Reason, _State) ->
    ct:pal("~p terminating with reason ~p~n", [?MODULE, Reason]),
    ok.
