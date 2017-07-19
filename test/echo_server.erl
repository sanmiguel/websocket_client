-module(echo_server).

-behaviour(cowboy_websocket_handler).

-export([
         start/0,
         stop/0
        ]).

-export([
         init/3,
         websocket_init/3,
         websocket_handle/3,
         websocket_info/3,
         websocket_terminate/3
        ]).

-record(state, {}).

start() ->
    Port = 8080,
    {ok, _} = application:ensure_all_started(cowboy),
    error_logger:info_msg("Starting ~p on port ~b.~n", [?MODULE, Port]),
    Dispatch = cowboy_router:compile([{'_', [
                                             {"/hello", ?MODULE, []},
                                             {'_', ?MODULE, []}
                                            ]}]),
    {ok, _} = cowboy:start_http(echo_listener, 2, [
                                                   {nodelay, true},
                                                   {port, Port},
                                                   {max_connections, 100}
                                                  ],
                                [{env, [{dispatch, Dispatch}]}]).

stop() ->
    cowboy:stop_listener(echo_listener).

init(_, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init(_Transport, Req, _Opts) ->
    case cowboy_req:qs_val(<<"code">>, Req) of
        {undefined, Req2} ->
            case cowboy_req:qs_val(<<"q">>, Req2) of
                {undefined, Req3} ->
                    {ok, Req3, #state{}};
                {Text, Req3} ->
                    self() ! {send, Text},
                    {ok, Req3, #state{}}
            end;
        {Code, Req2} ->
            IntegerCode = list_to_integer(binary_to_list(Code)),
            error_logger:info_msg("~p shuting down on init using '~p' status code~n", [?MODULE, IntegerCode]),
            {ok, Req3} = cowboy_req:reply(IntegerCode, Req2),
            {shutdown, Req3}
    end.

websocket_handle({ping, Payload}=_Frame, Req, State) ->
    error_logger:info_msg("~p pingpong with size ~p~n", [?MODULE, byte_size(Payload)]),
    {ok, Req, State};
websocket_handle({Type, Payload}=Frame, Req, State) ->
    error_logger:info_msg("~p replying with ~p of size ~p~n", [?MODULE, Type, byte_size(Payload)]),
    {reply, Frame, Req, State}.

websocket_info({send, Text}, Req, State) ->
    timer:sleep(1),
    error_logger:info_msg("~p sent frame of size ~p ~n", [?MODULE, byte_size(Text)]),
    {reply, {text, Text}, Req, State};

websocket_info(_Msg, Req, State) ->
    error_logger:info_msg("~p received OoB msg: ~p~n", [?MODULE, _Msg]),
    {ok, Req, State}.

websocket_terminate(Reason, _Req, _State) ->
    error_logger:info_msg("~p terminating with reason ~p~n", [?MODULE, Reason]),
    ok.
