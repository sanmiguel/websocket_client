%% @author Jeremy Ong
%% @author Michael Coles
%% @doc Erlang websocket client (FSM implementation)
-module(websocket_client).

-behaviour(gen_statem).
%-compile([export_all]).

-include("websocket_req.hrl").

-export([start_link/3]).
-export([start_link/4]).
-export([start_link/5]).
-export([cast/2]).
-export([send/2]).

-export([callback_mode/0]).
-export([init/1]).
-export([terminate/3]).
-export([handle_event/4]).
-export([code_change/4]).

% States
-export([disconnected/3]).
-export([connected/3]).
-export([handshaking/3]).

-type state_name() :: atom().

-type state() :: any().
-type keepalive() :: non_neg_integer().
-type close_type() :: normal | error | remote.
-type reason() :: term().

% Create handler state based on options.
-callback init(list()) ->
    {ok, state()} % Will start `disconnected`.
    | {once, state()} % Will attempt to connect once only.
    | {reconnect, state()}. % Will keep trying to connect.

% Called when a websocket connection is established, including
% successful handshake with the other end.
-callback onconnect(websocket_req:req(), state()) ->
    % Simple client: only server-initiated pings will be
    % automatically responded to.
    {ok, state()}
    % Keepalive client: will automatically initiate a ping to the server
    % every keepalive() ms.
    | {ok, state(), keepalive()}
    % Immediately send a message to the server.
    | {reply, websocket_req:frame(), state()}
    % Close the connection.
    | {close, binary(), state()}.

% Called when the socket is closed for any reason.
-callback ondisconnect(reason(), state()) ->
    % Return to `disconnected` state but keep process alive.
    {ok, state()}
    % Immediately attempt to reconnect.
    | {reconnect, state()}
    % Reconnect after interval.
    | {reconnect, non_neg_integer(), state()}
    % Shut the process down cleanly.
    | {close, reason(), state()}.

% Called for every received frame from the server.
% NB this will also get called for pings, which are automatically ponged.
-callback websocket_handle({text | binary | ping | pong, binary()}, websocket_req:req(), state()) ->
    % Do nothing.
    {ok, state()}
    % Send the given frame to the server.
    | {reply, websocket_req:frame(), state()}
    % Shut the process down cleanly.
    | {close, binary(), state()}.

% Called for any received erlang message.
-callback websocket_info(any(), websocket_req:req(), state()) ->
    % Do nothing.
    {ok, state()}
    % Send the given frame to the server.
    | {reply, websocket_req:frame(), state()}
    % Shut the process down cleanly.
    | {close, binary(),  state()}.

% Called when the process exits abnormally.
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
         buffer = <<>> :: binary(),
         reconnect :: boolean(),
         ka_attempts = 0 :: non_neg_integer()
        }).

%% @doc Start the websocket client
%%
%% URL : Supported schema: (ws | wss)
%% Handler: module()
%% Args : arguments to pass to Handler:init/1
-spec start_link(URL :: string(), Handler :: module(), Args :: list()) ->
    {ok, pid()} | {error, term()}.
start_link(URL, Handler, Args) ->
    start_link(URL, Handler, Args, []).

%% @doc Start the websocket client
%%
%% Supported Opts:
%%  - {keepalive, integer()}:  keepalive timeout in ms
%%  - {extra_headers, list({K, V})}: a kv-list of headers to send in the handshake
%% (useful if you need to add an e.g. 'Origin' header on connection.
%%  - {ssl_verify, verify_none | verify_peer | {verify_fun, _}} : this is passed
%%  through to ssl:connect/2,3.
start_link(URL, Handler, HandlerArgs, Opts) ->
    start_link(undefined, URL, Handler, HandlerArgs, Opts).

%% @doc Start the websocket client
%% see gen_fsm:start_link(FsmName, Module, Args, Options)
%% FsmName = {local,Name} | {global,GlobalName} | {via,Module,ViaName}
%%  Name = atom()
%%  GlobalName = ViaName = term()
%%  Module = atom()
start_link(FsmName, URL, Handler, HandlerArgs, Opts) when is_binary(URL) ->
  start_link(FsmName, binary_to_list(URL), Handler, HandlerArgs, Opts);
start_link(FsmName, URL, Handler, HandlerArgs, Opts) when is_list(Opts) ->
    case uri_string:parse(URL) of
        #{scheme := Scheme, host := Host} = Parsed ->
            Port = maps:get(port, Parsed, default_scheme_port(Scheme)),
            FormattedPath = path(Parsed) ++ query_string(Parsed),
            InitArgs = {scheme(Scheme), Host, Port, FormattedPath, Handler, HandlerArgs, Opts},
            % FsmOpts = [{debug, [log, trace]}],
            FsmOpts = [],
            fsm_start_link(FsmName, InitArgs, FsmOpts);

        {error, _, _} = Error ->
            Error
    end.

%% http_uri presumed a path of "/" even
%% when no path was provided.
path(#{path := []}) ->
    "/";
path(#{path := Path}) ->
    Path.

%% http_uri prefixed the query string while
%% string_uri does not.
query_string(#{query := Query}) ->
    "?" ++ Query;
query_string(_) ->
    "".

scheme("ws") ->
    ws;
scheme("wss") ->
    wss.

default_scheme_port("ws") ->
    80;
default_scheme_port("wss") ->
    443.

fsm_start_link(undefined, Args, Options) ->
    gen_statem:start_link(?MODULE, Args, Options);
fsm_start_link(FsmName, Args, Options) ->
    gen_statem:start_link(FsmName, ?MODULE, Args, Options).

send(Client, Frame) ->
    gen_statem:call(Client, {send, Frame}).

%% Send a frame asynchronously
-spec cast(Client :: pid(), websocket_req:frame()) -> ok.
cast(Client, Frame) ->
    gen_statem:cast(Client, {cast_frame, Frame}).

-spec callback_mode() -> state_functions.
callback_mode() ->
    state_functions.

-type scheme() :: ws | wss.
-type opt() :: {keepalive, keepalive()}
		      | {extra_headers, list({string(), string()})}
		      | {ssl_verify, verify_none | verify_peer | {verify_fun, term()}}
		      | {socket_opts, list(term())}.
-type init_args() ::
	{Scheme :: scheme(),
	 Host :: string(),
	 Port :: integer(),
	 Path :: string(),
	 Handler :: atom(),
	 HandlerArgs :: list(any()),
	 Opts :: list(opt())}.

-spec init(init_args()) ->
    {ok, state_name(), #context{}}
    | {ok, state_name(), #context{}, [{next_event, internal, connect}]}.
    %% NB DO NOT try to use Timeout to do keepalive.
init({Protocol, Host, Port, Path, Handler, HandlerArgs, Opts}) ->
    {Connect, Reconnect, HState} =
        case Handler:init(HandlerArgs) of
            {ok, State} -> {false, false, State};
            {once, State} -> {true, false, State};
            {reconnect, State} -> {true, true, State}
        end,
    SSLVerify = proplists:get_value(ssl_verify, Opts, verify_none),
    SockOpts  = proplists:get_value(socket_opts, Opts, []),
    Transport = transport(Protocol, ssl_verify(SSLVerify), SockOpts),
    WSReq = websocket_req:new(
                Protocol, Host, Port, Path,
                Transport, wsc_lib:generate_ws_key()
            ),
    WSReq1 = case proplists:get_value(keepalive, Opts) of
        undefined -> WSReq;
        KeepAlive ->
            % NB: there's no need to start the actual KA mechanism until we're
            % actually connected.
            websocket_req:keepalive(KeepAlive, WSReq)
    end,
    Context0 = #context{
                  transport = Transport,
                  headers   = proplists:get_value(extra_headers, Opts, []),
                  wsreq     = WSReq1,
                  target    = {Protocol, Host, Port, Path},
                  handler   = {Handler, HState},
                  reconnect = Reconnect
                 },
    {ok, disconnected, Context0,
     [ {next_event, internal, connect} || Connect ]}.

-spec transport(ws | wss, {verify | verify_fun, term()},
                list(term())) -> #transport{}.
transport(wss, SSLVerify, ExtraOpts) ->
    #transport{
       mod = ssl,
       name = ssl,
       closed = ssl_closed,
       error = ssl_error,
       opts = [
               {mode, binary},
               {active, true},
               SSLVerify,
               {packet, 0}
               | ExtraOpts
              ]};
transport(ws, _, ExtraOpts) ->
    #transport{
        mod = gen_tcp,
        name = tcp,
        closed = tcp_closed,
        error = tcp_error,
        opts = [
                {mode, binary},
                {active, true},
                {packet, 0}
                | ExtraOpts
               ]}.

ssl_verify(verify_none) ->
    {verify, verify_none};
ssl_verify(verify_peer) ->
    {verify, verify_peer};
ssl_verify({verify_fun, _}=Verify) ->
    Verify.

-spec terminate(Reason :: term(), state_name(), #context{}) -> ok.
%% TODO Use Reason!!
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
           target={_Protocol, Host, Port, _Path},
           ka_attempts=KAs
          }=Context) ->
    case (T#transport.mod):connect(Host, Port, T#transport.opts, 6000) of
        {ok, Socket} ->
            WSReq1 = websocket_req:socket(Socket, WSReq0),
            case send_handshake(WSReq1, Headers) of
                ok ->
                    case websocket_req:keepalive(WSReq1) of
                        infinity ->
                            {next_state, handshaking, Context#context{ wsreq=WSReq1}};
                        KeepAlive ->
                            NewTimer = erlang:send_after(KeepAlive, self(), keepalive),
                            WSReq2 = websocket_req:set([{keepalive_timer, NewTimer}], WSReq1),
                            {next_state, handshaking, Context#context{ wsreq=WSReq2, ka_attempts=(KAs+1)}}
                    end;
                Error ->
                    disconnect(Error, Context)
            end;
        {error,_}=Error ->
            disconnect(Error, Context)
    end.

disconnect(Reason, #context{
                      wsreq=WSReq0,
                      handler={Handler, HState0}
                     }=Context) ->
    case Handler:ondisconnect(Reason, HState0) of
        {ok, HState1} ->
            {next_state, disconnected, Context#context{buffer = <<>>, handler={Handler, HState1}}};
        {reconnect, HState1} ->
            {next_state, disconnected, Context#context{handler={Handler, HState1}},
             {next_event, cast, connect}};
        {reconnect, Interval, HState1} ->
            {next_state, disconnected, Context#context{handler={Handler, HState1}},
             {{timeout, connect}, Interval, connect}};
        {close, Reason1, HState1} ->
            ok = websocket_close(WSReq0, Handler, HState1, Reason1),
            {stop, Reason1, Context#context{handler={Handler, HState1}}}
    end.

disconnected(info, {TransClosed, _Sock},
          #context{
             transport=#transport{ closed=TransClosed } %% NB: matched
            }=Context) ->
    disconnect({remote, closed}, Context);
disconnected(info, Msg, Context) ->
    handle_info(Msg, Context);
disconnected(internal, connect, Context0) ->
    connect(Context0);
disconnected({timeout, connect}, connect, Context0) ->
    connect(Context0);
disconnected(internal, _, _) ->
    keep_state_and_data;
disconnected({call, From}, connect, Context0) ->
    case connect(Context0) of
        {next_state, State, Context1} ->
            {next_state, State, Context1, [{reply, From, ok}]} ;
        Other ->
            Other
    end;
disconnected({call, From}, _, _) ->
    {keep_state_and_data, {reply, From, {error, unhandled_sync_event}}}.

connected({timeout, connect}, connect, _Context) ->
    keep_state_and_data;
connected({timeout, keepalive}, keepalive, Context) ->
    handle_keepalive(connected, Context);
connected(info, keepalive, Context) ->
    handle_keepalive(connected, Context);
connected(info, {TransClosed, _Sock},
          #context{
             transport=#transport{ closed=TransClosed } %% NB: matched
            }=Context) ->
    disconnect({remote, closed}, Context);
connected(info, {TransError, _Sock, Reason},
            #context{
               transport=#transport{ error=TransError},
               handler={Handler, HState0},
               wsreq=WSReq
              }=Context) ->
    ok = websocket_close(WSReq, Handler, HState0, {TransError, Reason}),
    {stop, {socket_error, Reason}, Context};
connected(info, {Trans, _Socket, Data},
          #context{
             transport=#transport{ name=Trans }
            }=Context) ->
    handle_websocket_frame(Data, Context);
connected(info, Msg, Context) ->
    handle_info(Msg, Context);
connected(internal, connect, Context) ->
    {next_state, connected, Context};
connected(cast, {cast_frame, Frame}, #context{wsreq=WSReq}=Context) ->
    case encode_and_send(Frame, WSReq) of
        ok ->
            {next_state, connected, Context};
        {error, closed} ->
            {next_state, disconnected, Context}
    end;
connected({call, From}, {send, Frame}, #context{wsreq=WSReq}) ->
    {keep_state_and_data, {reply, From, encode_and_send(Frame, WSReq)}};
connected({call, From}, _Event, _Context) ->
    {keep_state_and_data, {reply, From, {error, unhandled_sync_event}}}.

handshaking({timeout, keepalive}, keepalive, Context) ->
    handle_keepalive(handshaking, Context);
handshaking(info, keepalive, Context) ->
    handle_keepalive(handshaking, Context);
handshaking(info, {TransClosed, _Sock},
          #context{
             transport=#transport{ closed=TransClosed } %% NB: matched
            }=Context) ->
    disconnect({remote, closed}, Context);
handshaking(info, {TransError, _Sock, Reason},
            #context{
               transport=#transport{ error=TransError},
               handler={Handler, HState0},
               wsreq=WSReq
              }=Context) ->
    ok = websocket_close(WSReq, Handler, HState0, {TransError, Reason}),
    {stop, {socket_error, Reason}, Context};
handshaking(info, {Trans, _Socket, Data},
            #context{
               transport=#transport{ name=Trans },
               wsreq=WSReq1,
               handler={Handler, HState0},
               buffer=Buffer
              }=Context) ->
    MaybeHandshakeResp = << Buffer/binary, Data/binary >>,
    case wsc_lib:validate_handshake(MaybeHandshakeResp, websocket_req:key(WSReq1)) of
        {error,_}=Error ->
            disconnect(Error, Context);
        {notfound, _} ->
            {next_state, handshaking, Context#context{buffer=MaybeHandshakeResp}};
        {ok, Remaining} ->
            {ok, HState2, KeepAlive} =
                case Handler:onconnect(WSReq1, HState0) of
                    {ok, HState1} ->
                        KA = websocket_req:keepalive(WSReq1),
                        {ok, HState1, KA};
                    {ok, _HS1, KA}=Result ->
                        erlang:send_after(KA, self(), keepalive),
                        Result
                end,
            WSReq2 = websocket_req:keepalive(KeepAlive, WSReq1),
            handle_websocket_frame(Remaining, Context#context{
                                                wsreq=WSReq2,
                                                handler={Handler, HState2},
                                                buffer= <<>>})
    end;
handshaking(info, Msg, Context) ->
    handle_info(Msg, Context);
handshaking({call, From}, _Event, _Context) ->
    {keep_state_and_data, {reply, From, {error, unhandled_sync_event}}};
handshaking(_EType, _Event, _Context) ->
    keep_state_and_data.

-spec handle_event(EventType::gen_statem:event_type(),
                   Event::term(),
                   State::atom(),
                   #context{}) ->
    keep_state_and_data.
handle_event(_, _, _, _) ->
    keep_state_and_data. %% i.e. ignore, do nothing

-spec handle_keepalive(state_name(), #context{}) ->
    {next_state, state_name(), #context{}}
    | {stop, Reason :: term(), #context{}}.
handle_keepalive(KAState, #context{ wsreq=WSReq, ka_attempts=KAAttempts }=Context)
  when KAState =:= handshaking; KAState =:= connected ->
    [KeepAlive, KATimer, KAMax] =
        websocket_req:get([keepalive, keepalive_timer, keepalive_max_attempts], WSReq),
    case KATimer of
        undefined -> ok;
        _ -> erlang:cancel_timer(KATimer)
    end,
    case KAAttempts of
        KAMax->
            disconnect({error, keepalive_timeout}, Context);
        _ ->
            case encode_and_send(ping, WSReq) of
                ok ->
                    NewTimer = erlang:send_after(KeepAlive, self(), keepalive),
                    WSReq1 = websocket_req:set([{keepalive_timer, NewTimer}], WSReq),
                    {next_state, KAState, Context#context{wsreq=WSReq1, ka_attempts=(KAAttempts+1)}};
                {error, _} = Reason ->
                    disconnect(Reason, Context)
            end
                    
    end.

-spec handle_info(Info :: term(), #context{}) ->
    {keep_state, #context{}}
    | {stop, Reason::term(), #context{}}.
%% TODO Move Socket into #transport{} from #websocket_req{} so that we can
%% match on it here
handle_info(Msg,
            #context{
               wsreq=WSReq,
               handler={Handler, HState0},
               buffer=Buffer
              }=Context) ->
    try Handler:websocket_info(Msg, WSReq, HState0) of
        HandlerResponse ->
            case handle_response(HandlerResponse, Handler, WSReq) of
                {ok, WSReqN, HStateN} ->
                    {keep_state, Context#context{
                                   handler={Handler, HStateN},
                                   wsreq=WSReqN,
                                   buffer=Buffer}};
                {close, Reason, WSReqN, Handler, HStateN} ->
                    {stop, Reason, Context#context{
                                     wsreq=WSReqN,
                                     handler={Handler, HStateN}}}
            end
    catch Class:Reason:StackTrace ->
        %% TODO Maybe a function_clause catch here to allow
        %% not having to have a catch-all clause in websocket_info CB?
        error_logger:error_msg(
          "** Websocket client ~p terminating in ~p/~p~n"
          "   for the reason ~p:~p~n"
          "** Last message was ~p~n"
          "** Handler state was ~p~n"
          "** Stacktrace: ~p~n~n",
          [Handler, websocket_info, 3, Class, Reason, Msg, HState0,
           StackTrace]),
        websocket_close(WSReq, Handler, HState0, Reason),
        {stop, Reason, Context}
    end.

% Recursively handle all frames that are in the buffer;
% If the last frame is incomplete, leave it in the buffer and wait for more.
handle_websocket_frame(Data, #context{}=Context0) ->
    Context = Context0#context{ka_attempts=0},
    #context{
               handler={Handler, HState0},
               wsreq=WSReq,
               buffer=Buffer} = Context,
    Result =
        case websocket_req:remaining(WSReq) of
            undefined ->
                wsc_lib:decode_frame(WSReq, << Buffer/binary, Data/binary >>); %% TODO ??
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
                case handle_response(HandlerResponse, Handler, WSReqN2) of
                    {ok, WSReqN2, HStateN2} ->
                        Context2 = Context#context{
                                     handler = {Handler, HStateN2},
                                     wsreq = WSReqN2,
                                     buffer = <<>>},
                        case BufferN of
                            <<>> ->
                                {next_state, connected, Context2};
                            _ ->
                                handle_websocket_frame(BufferN, Context2)
                        end;
                    {close, Error, WSReqN2, Handler, HStateN2} ->
                        {stop, Error, Context#context{
                                         wsreq=WSReqN2,
                                         handler={Handler, HStateN2}}}
                end
            catch Class:Reason:StackTrace ->
              error_logger:error_msg(
                "** Websocket client ~p terminating in ~p/~p~n"
                "   for the reason ~p:~p~n"
                "** Websocket message was ~p~n"
                "** Handler state was ~p~n"
                "** Stacktrace: ~p~n~n",
                [Handler, websocket_handle, 3, Class, Reason, Message, HState0,
                  StackTrace]),
              {stop, Reason, Context#context{ wsreq=WSReqN }}
            end;
        {recv, WSReqN, BufferN} ->
            {next_state, connected, Context#context{
                                      handler={Handler, HState0},
                                      wsreq=WSReqN,
                                      buffer=BufferN}};
        {close, _Reason, WSReqN} ->
            {next_state, disconnected, Context#context{wsreq=WSReqN,
                                                       buffer= <<>>}}
    end.


-spec code_change(OldVsn :: term(), state_name(), #context{}, Extra :: any()) ->
    {ok, state_name(), #context{}}.
code_change(_OldVsn, StateName, Context, _Extra) ->
    {ok, StateName, Context}.

%% @doc Handles return values from the callback module
handle_response({ok, HandlerState}, _Handler, WSReq) ->
    {ok, WSReq, HandlerState};
handle_response({reply, Frame, HandlerState}, Handler, WSReq) ->
    case encode_and_send(Frame, WSReq) of
        ok -> {ok, WSReq, HandlerState};
        Reason -> {close, Reason, WSReq, Handler, HandlerState}
    end;
handle_response({close, Payload, HandlerState}, Handler, WSReq) ->
    encode_and_send({close, Payload}, WSReq),
    {close, normal, WSReq, Handler, HandlerState}.

%% @doc Send http upgrade request and validate handshake response challenge
-spec send_handshake(WSReq :: websocket_req:req(), [{string(), string()}]) ->
    ok
    | {error, term()}.
send_handshake(WSReq, ExtraHeaders) ->
    Handshake = wsc_lib:create_handshake(WSReq, ExtraHeaders),
    [Transport, Socket] = websocket_req:get([transport, socket], WSReq),
    (Transport#transport.mod):send(Socket, Handshake).

%% @doc Send frame to server
encode_and_send(Frame, WSReq) ->
    case websocket_req:get([socket, transport], WSReq) of
        [undefined, _Transport] ->
            {error, disconnected};
        [Socket, Transport] ->
            (Transport#transport.mod):send(Socket, wsc_lib:encode_frame(Frame))
    end.

-spec websocket_close(WSReq :: websocket_req:req(),
                      Handler :: module(),
                      HandlerState :: any(),
                      Reason :: tuple()) -> ok.
websocket_close(WSReq, Handler, HandlerState, Reason) ->
    try
        Handler:websocket_terminate(Reason, WSReq, HandlerState)
    catch Class:Reason2:StackTrace ->
      error_logger:error_msg(
        "** Websocket handler ~p terminating in ~p/~p~n"
        "   for the reason ~p:~p~n"
        "** Handler state was ~p~n"
        "** Stacktrace: ~p~n~n",
        [Handler, websocket_terminate, 3, Class, Reason2, HandlerState,
          StackTrace])
    end.
%% TODO {stop, Reason, Context}
