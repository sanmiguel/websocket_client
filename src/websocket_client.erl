-module(websocket_client).
%% @author Jeremy Ong
%% @author Michael Coles
%% @doc Erlang websocket client (FSM implementation)

-behaviour(gen_fsm).
%-compile([export_all]).

-include("websocket_req.hrl").

-export([start_link/3]).
-export([start_link/4]).
-export([cast/2]).
-export([send/2]).

-export([init/1]).
-export([terminate/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).

% States
-export([disconnected/2]).
-export([disconnected/3]).
-export([connected/2]).
-export([connected/3]).
-export([handshaking/2]).
-export([handshaking/3]).

-type state_name() :: atom().

-type state() :: any().
-type keepalive() :: integer().
-type close_type() :: normal | error | remote.
-type reason() :: term().

-callback init(list()) ->
    {ok, state()}.
    %| {ok, state(), keepalive()}.
%% TODO FIXME Actually handle the keepalive case

-callback onconnect(websocket_req:req(), state()) ->
    {ok, state()}
    | {ok, state(), keepalive()}
    | {reply, websocket_req:frame(), state()}
    | {close, binary(), state()}.

-callback ondisconnect(reason(), state()) ->
    {ok, state()}
        | {reconnect, state()}
        | {close, reason(), state()}.

-callback websocket_handle({text | binary | ping | pong, binary()}, websocket_req:req(), state()) ->
    {ok, state()}
        | {reply, websocket_req:frame(), state()}
        | {close, binary(), state()}.

-callback websocket_info(any(), websocket_req:req(), state()) ->
    {ok, state()}
        | {reply, websocket_req:frame(), state()}
        | {close, binary(),  state()}.

-callback websocket_terminate({close_type(), term()} | {close_type(), integer(), binary()},
                              websocket_req:req(), state()) ->
    ok.

-record(context,
        {
         wsreq     :: websocket_req:req(),
         transport :: #transport{},
         headers   :: list({string(), string()}),
         target    :: {Proto :: ws | wss,
                      Host :: string(), Port :: non_neg_integer(),
                      Path :: string()},
         handler   :: {module(), HState :: term()},
         buffer = <<>> :: binary()
        }).

%% @doc Start the websocket client
-spec start_link(URL :: string(), Handler :: module(), Args :: list()) ->
    {ok, pid()} | {error, term()}.
start_link(URL, Handler, Args) ->
    start_link(URL, Handler, Args, []).

start_link(URL, Handler, HandlerArgs, AsyncStart) when is_boolean(AsyncStart) ->
    start_link(URL, Handler, HandlerArgs, [{async_start, AsyncStart}]);
start_link(URL, Handler, HandlerArgs, Opts) when is_list(Opts) ->
    case http_uri:parse(URL, [{scheme_defaults, [{ws,80},{wss,443}]}]) of
        {ok, {Protocol, _, Host, Port, Path, Query}} ->
            InitArgs = [Protocol, Host, Port, Path ++ Query, Handler, HandlerArgs, Opts],
            %FsmOpts = [{dbg, [trace]}],
            FsmOpts = [],
            gen_fsm:start_link(?MODULE, InitArgs, FsmOpts);
        {error, _} = Error ->
            Error
    end.

send(Client, Frame) ->
    gen_fsm:sync_send_event(Client, {send, Frame}).

%% Send a frame asynchronously
-spec cast(Client :: pid(), websocket_req:frame()) -> ok.
cast(Client, Frame) ->
    gen_fsm:send_event(Client, {cast, Frame}).

-spec init(list(any())) ->
    {ok, state_name(), #context{}}
    %% NB DO NOT try to use Timeout to do keepalive.
    | {stop, Reason :: term()}.
init([Protocol, Host, Port, Path, Handler, HandlerArgs, Opts]) ->
    {ok, HState} = Handler:init(HandlerArgs), %% TODO More rigorous checks of return values
                                       %% e.g. {error, Reason}
    AsyncStart = proplists:get_value(async_start, Opts, false),
    Transport =
        case Protocol of
            wss ->
                #transport{
                   mod = ssl,
                   name = ssl,
                   closed = ssl_closed,
                   error = ssl_error,
                   opts = [
                           {mode, binary},
                           {active, AsyncStart},
                           {verify, verify_none},
                           {packet, 0}
                          ]};
            ws  ->
                #transport{
                    mod = gen_tcp,
                    name = tcp,
                    closed = tcp_closed,
                    error = tcp_error,
                    opts = [
                            binary,
                            {active, AsyncStart},
                            {packet, 0}
                           ]}
        end,
    WSReq = websocket_req:new(
                Protocol, Host, Port, Path,
                undefined, Transport,
                wsc_lib:generate_ws_key()
            ),
    Context0 = #context{
                  transport = Transport,
                  headers = proplists:get_value(extra_headers, Opts, []),
                  wsreq   = WSReq,
                  target  = {Protocol, Host, Port, Path},
                  handler = {Handler, HState}
                 },
    if AsyncStart ->
           %% In async start mode, we return as quickly as possible, letting handshaking
           %% etc happen in the background
           gen_fsm:send_event(self(), connect),
           {ok, disconnected, Context0};
       true ->
           %% In synchronous start mode, we need to connect and handshake before we return
           %% control to the caller - also switch back to active mode for the socket
           case connect(Context0) of
               {error, ConnErr}->
                   {stop, ConnErr};
               {ok, #context{
                       wsreq=WSReq1,
                       handler={Handler, HState0}
                      }=Context1} ->
                   case wait_for_handshake(WSReq1) of
                       {ok, Data} ->
                           {ok, HState2, KeepAlive} =
                               case Handler:onconnect(WSReq1, HState0) of
                                   {ok, HState1} -> {ok, HState1, infinity};
                                   {ok, _HS1, KA}=Result ->
                                       erlang:send_after(KA, self(), keepalive),
                                       Result
                               end,
                           WSReq2 = websocket_req:keepalive(KeepAlive, WSReq1),
                           {ok, connected, Context1#context{
                                             wsreq=WSReq2,
                                             handler={Handler, HState2},
                                             buffer=Data
                                            }};
                       {error, HSErr}->
                           {stop, HSErr}
                   end
           end
    end.

-spec terminate(Reason :: term(), state_name(), #context{}) -> ok.
%% TODO Use Reason!!
terminate(_Reason, _StateName, #context{wsreq=undefined}) ->
    ok;
terminate(_Reason, _StateName,
          #context{
             transport=T,
             wsreq=WSReq
            }) ->
    case websocket_req:socket(WSReq) of
        undefined -> ok;
        Socket ->
            _ = (T#transport.mod):close(Socket)
    end,
    ok.

connect(#context{
           transport=T,
           wsreq=WSReq0,
           headers=Headers,
           target={_Protocol, Host, Port, _Path}
          }=Context) ->
    case (T#transport.mod):connect(Host, Port, T#transport.opts, 6000) of
        {ok, Socket} ->
            WSReq1 = websocket_req:socket(Socket, WSReq0),
            ok = send_handshake(WSReq1, Headers),
            {ok, Context#context{ wsreq=WSReq1}};
        {error,_}=Error ->
            Error
    end.

wait_for_handshake(WSReq) ->
    wait_for_handshake(<<>>, WSReq).
wait_for_handshake(Buffer, #websocket_req{
                      socket=Socket,
                      transport=T
                     }=WSReq) ->
    %% TODO Find a graceful way to handle gen_tcp/ssl/inet module diffs
    OptMod = case T#transport.mod of
                 gen_tcp -> inet;
                 ssl -> ssl
             end,
    OptMod:setopts(Socket, [{active, false}]),
    case (T#transport.mod):recv(Socket, 0, 6000) of
        {ok, Data} ->
            case wsc_lib:validate_handshake(<< Buffer/binary, Data/binary >>, websocket_req:key(WSReq)) of
                {error, _}=VerifyError -> VerifyError;
                {notfound, Remainder} ->
                    wait_for_handshake(Remainder, WSReq);
                {ok, Remainder} ->
                    ok = OptMod:setopts(Socket, [{active, true}]),
                    {ok, Remainder}
            end;
        {error, _}=RecvError ->
            RecvError
    end.

-spec handle_event(Event :: term(), state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}.
handle_event(_Event, State, Context) ->
    {next_state, State, Context}. %% i.e. ignore, do nothing

-spec handle_sync_event(Event :: term(), From :: pid(), state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {reply, Reply :: term(), state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}
    | {stop, Reason :: term(), Reply :: term(), #context{}}.
handle_sync_event(Event, {_From, Tag}, State, Context) ->
    {reply, {noop, Event, Tag}, State, Context}.

-spec handle_info(Info :: term(), state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}.
handle_info(keepalive, KAState, #context{ wsreq=WSReq }=Context)
  when KAState =:= handshaking; KAState =:= connected ->
    [KeepAlive, KATimer] =
        websocket_req:get([keepalive, keepalive_timer], WSReq),
    case KATimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(KATimer)
    end,
    ok = encode_and_send({ping, <<"foo">>}, WSReq),
    NewTimer = erlang:send_after(KeepAlive, self(), keepalive),
    WSReq1 = websocket_req:set([{keepalive_timer, NewTimer}], WSReq),
    {next_state, KAState, Context#context{wsreq=WSReq1}};
%% TODO Move Socket into #transport{} from #websocket_req{} so that we can
%% match on it here
handle_info({TransClosed, _Socket}, _CurrState,
            #context{
               transport=#transport{ closed=TransClosed },
               wsreq=WSReq,
               handler={Handler, HState0}
              }=Context) ->
    case Handler:ondisconnect({remote, closed}, HState0) of
        {ok, HState1} ->
            {next_state, disconnected, Context#context{handler={Handler, HState1}}};
        {reconnect, HState1} ->
            ok = gen_fsm:send_event(self(), connect),
            {next_state, disconnected, Context#context{handler={Handler, HState1}}};
        {close, Reason, HState1} ->
            ok = websocket_close(WSReq, Handler, HState1, Reason),
            {stop, socket_closed, Context#context{handler={Handler, HState1}}}
    end;
handle_info({TransError, _Socket, Reason},
            _AnyState,
            #context{
               transport=#transport{ error=TransError},
               handler={Handler, HState0},
               wsreq=WSReq
              }=Context) ->
    ok = websocket_close(WSReq, Handler, HState0, {TransError, Reason}),
    {stop, {socket_error, Reason}, Context};
handle_info({Trans, Socket, Data},
            handshaking,
            #context{
               transport=#transport{ name=Trans },
               wsreq=WSReq1,
               handler={Handler, HState0},
               buffer=Buffer
              }=Context) ->
    MaybeHandshakeResp = << Buffer/binary, Data/binary >>,
    case wsc_lib:validate_handshake(MaybeHandshakeResp, websocket_req:key(WSReq1)) of
        {error,_}=Error ->
            {stop, Error, Context};
        {notfound, _} ->
            {next_state, handshaking, Context#context{buffer=MaybeHandshakeResp}};
        {ok, Remaining} ->
            {ok, HState2, KeepAlive} =
                case Handler:onconnect(WSReq1, HState0) of
                    {ok, HState1} -> {ok, HState1, infinity};
                    {ok, _HS1, KA}=Result ->
                        erlang:send_after(KA, self(), keepalive),
                        Result
                end,
            WSReq2 = websocket_req:keepalive(KeepAlive, WSReq1),
            %% TODO This is nasty and hopefully there's a nicer way
            self() ! {Trans, Socket, Remaining},
            {next_state, connected, Context#context{
                                      wsreq=WSReq2,
                                      handler={Handler, HState2},
                                      buffer = <<>>}}
    end;
handle_info({Trans, _Socket, Data},
            connected,
            #context{
               transport=#transport{ name=Trans },
               handler={Handler, HState0},
               wsreq=WSReq,
               buffer=Buffer
              }=Context) ->
    Result =
        case websocket_req:remaining(WSReq) of
            undefined ->
                wsc_lib:decode_frame(WSReq, << Buffer/binary, Data/binary >>);
            Remaining ->
                wsc_lib:decode_frame(WSReq, websocket_req:opcode(WSReq), Remaining, Data, Buffer)
        end,
    case Result of
        {frame, Message, WSReqN, BufferN} ->
            case Message of
                {ping, Payload} -> ok = encode_and_send({pong, Payload}, WSReqN);
                _ -> ok
            end,
            try
                HandlerResponse = Handler:websocket_handle(Message, WSReqN, HState0),
                WSReqN2 = websocket_req:remaining(undefined, WSReqN),
                case handle_response(HandlerResponse, Handler, BufferN, WSReqN2) of
                    {ok, WSReqN2, HStateN2, BufferN2} ->
                        {next_state, connected, Context#context{
                                                  handler={Handler, HStateN2},
                                                  wsreq=WSReqN2,
                                                  buffer=BufferN2}};
                    {close, Error, WSReqN2, Handler, HStateN2} ->
                        {stop, Error, Context#context{
                                         wsreq=WSReqN2,
                                         handler={Handler, HStateN2}}}
                end
            catch Class:Reason ->
              error_logger:error_msg(
                "** Websocket client ~p terminating in ~p/~p~n"
                "   for the reason ~p:~p~n"
                "** Websocket message was ~p~n"
                "** Handler state was ~p~n"
                "** Stacktrace: ~p~n~n",
                [Handler, websocket_handle, 3, Class, Reason, Message, HState0,
                  erlang:get_stacktrace()]),
              {stop, Reason, Context#context{ wsreq=WSReqN }}
            end;
        {recv, WSReqN, BufferN} ->
            {next_state, connected, Context#context{
                                      handler={Handler, HState0},
                                      wsreq=WSReqN,
                                      buffer=BufferN}};
        {close, Reason, WSReqN} ->
            {stop, Reason, Context#context{ wsreq=WSReqN}}
    end;
handle_info(Msg, State,
            #context{
               wsreq=WSReq,
               handler={Handler, HState0},
               buffer=Buffer
              }=Context) ->
    try Handler:websocket_info(Msg, WSReq, HState0) of
        HandlerResponse ->
            case handle_response(HandlerResponse, Handler, Buffer, WSReq) of
                {ok, WSReqN, HStateN, BufferN} ->
                    {next_state, State, Context#context{
                                          handler={Handler, HStateN},
                                          wsreq=WSReqN,
                                          buffer=BufferN}};
                {close, Reason, WSReqN, Handler, HStateN} ->
                    {stop, Reason, Context#context{
                                     wsreq=WSReqN,
                                     handler={Handler, HStateN}}}
            end
    catch Class:Reason ->
        %% TODO Maybe a function_clause catch here to allow
        %% not having to have a catch-all clause in websocket_info CB?
        error_logger:error_msg(
          "** Websocket client ~p terminating in ~p/~p~n"
          "   for the reason ~p:~p~n"
          "** Last message was ~p~n"
          "** Handler state was ~p~n"
          "** Stacktrace: ~p~n~n",
          [Handler, websocket_info, 3, Class, Reason, Msg, HState0,
           erlang:get_stacktrace()]),
        websocket_close(WSReq, Handler, HState0, Reason),
        {stop, Reason, Context}
    end.

-spec code_change(OldVsn :: term(), state_name(), #context{}, Extra :: any()) ->
    {ok, state_name(), #context{}}.
code_change(_OldVsn, StateName, Context, _Extra) ->
    {ok, StateName, Context}.

disconnected(connect, Context0) ->
    case connect(Context0) of
        {ok, Context1} ->
            {next_state, handshaking, Context1};
        {error, _Error} ->
            {next_state, disconnected, Context0}
    end;
disconnected(_Event, Context) ->
    % ignore
    {next_state, disconnected, Context}.

disconnected(connect, _From, Context0) ->
    case connect(Context0) of
        {ok, Context1} ->
            {reply, ok, handshaking, Context1};
        {error,_}=Error ->
            {reply, Error, disconnected, Context0}
    end;
disconnected(_Event, _From, Context) ->
    {reply, {error, unhandled_sync_event}, disconnected, Context}.

connected({cast, Frame}, #context{wsreq=WSReq}=Context) ->
    case encode_and_send(Frame, WSReq) of
        ok ->
            {next_state, connected, Context};
        {error, closed} ->
            {next_state, disconnected, Context}
    end.

connected({send, Frame}, _From, #context{wsreq=WSReq}=Context) ->
    {reply, encode_and_send(Frame, WSReq), connected, Context};
connected(_Event, _From, Context) ->
    {reply, {error, unhandled_sync_event}, connected, Context}.

handshaking(_Event, Context) ->
    {next_state, handshaking, Context}.
handshaking(_Event, _From, Context) ->
    {reply, {error, unhandled_sync_event}, handshaking, Context}.

%% @doc Handles return values from the callback module
handle_response({ok, HandlerState}, _Handler, Buffer, WSReq) ->
    {ok, WSReq, HandlerState, Buffer};
handle_response({reply, Frame, HandlerState}, Handler, Buffer, WSReq) ->
    case encode_and_send(Frame, WSReq) of
        ok -> {ok, WSReq, HandlerState, Buffer};
        Reason -> {close, Reason, WSReq, Handler, HandlerState}
    end;
handle_response({close, Payload, HandlerState}, Handler, _, WSReq) ->
    ok = encode_and_send({close, Payload}, WSReq),
    {close, normal, WSReq, Handler, HandlerState}.

%% @doc Send http upgrade request and validate handshake response challenge
-spec send_handshake(WSReq :: websocket_req:req(), [{string(), string()}]) ->
    {ok, binary()}
    | {error, term()}.
send_handshake(WSReq, ExtraHeaders) ->
    Handshake = wsc_lib:create_handshake(WSReq, ExtraHeaders),
    [Transport, Socket] = websocket_req:get([transport, socket], WSReq),
    (Transport#transport.mod):send(Socket, Handshake).

%% @doc Send frame to server
encode_and_send(Frame, WSReq) ->
    [Socket, Transport] = websocket_req:get([socket, transport], WSReq),
    (Transport#transport.mod):send(Socket, wsc_lib:encode_frame(Frame)).

-spec websocket_close(WSReq :: websocket_req:req(),
                      Handler :: module(),
                      HandlerState :: any(),
                      Reason :: tuple()) -> ok.
websocket_close(WSReq, Handler, HandlerState, Reason) ->
    try
        Handler:websocket_terminate(Reason, WSReq, HandlerState)
    catch Class:Reason2 ->
      error_logger:error_msg(
        "** Websocket handler ~p terminating in ~p/~p~n"
        "   for the reason ~p:~p~n"
        "** Handler state was ~p~n"
        "** Stacktrace: ~p~n~n",
        [Handler, websocket_terminate, 3, Class, Reason2, HandlerState,
          erlang:get_stacktrace()])
    end.
%% TODO {stop, Reason, Context}
