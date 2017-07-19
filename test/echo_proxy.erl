-module(echo_proxy).

-export([start/0, start/1, listen/0]).
%% A single process that waits to receive an inbound connection on
%% port 8081. Upon receipt of connection, it makes an outbound connection
%% to port 8080 and forwards all traffic back and forth.
%%
%% TODO: Filter according to ~rules
%%

%%     decode_frame/2,5 ->
%%     % Incomplete frame:
%%     {recv, websocket_req:req(), IncompleteFrame :: binary()}
%%     % Complete frame, possibly extra bytes from next frame(s)
%%     | {frame, {OpcodeName :: atom(), Payload :: binary()},
%%                    websocket_req:req(), Rest :: binary()}
%%     % Close frame
%%     | {close, Reason :: term(), websocket_req:req()}.
%% Handler fun:
%% fun(server | client, Dest::socket(), RawData::binary(), 
%% Decoded :: {frame, frame(), websocket_req(), Rest::binary()}
%%             | {close, Reason :: term(), websocket_req()} )
%%             ->
%%             {ok, Buffer} %% 

%% TODO Replace error_logger:* with ct:log/n

block_pongs(server, _, _, {frame, {ping, Foo}, _, <<>>}) ->
    error_logger:info_msg("[PROXY][~p] {ping, ~s} BLOCKED", [server, Foo]),
    ok;
block_pongs(Name, _, _, {frame, {pong, Foo}, _, <<>>}) ->
    error_logger:info_msg("[PROXY][~p] {pong, ~s} BLOCKED", [Name, Foo]),
    ok;
block_pongs(Name, DstSock, RawData, {frame, Decoded, _, Rest}) ->
    error_logger:info_msg("[PROXY][~s]: ~p ~p~n", [Name, Decoded, Rest]),
    gen_tcp:send(DstSock, RawData).

-define(TCP_OPTS,
        [binary, {active, false}, {packet, 0}, {reuseaddr, true}]).

start() ->
    spawn(fun listen/0).

start(Fun) ->
    spawn(fun () -> listen(Fun) end).

listen() ->
    listen(fun block_pongs/4).

listen(Fun) ->
    error_logger:info_msg("[PROXY] starting on 8081"),
    {ok, LSock} = gen_tcp:listen(8081, ?TCP_OPTS),
    accept(LSock, Fun).

accept(LSock, Fun) ->
    {ok, CliSock} = gen_tcp:accept(LSock),
    %% TODO Configurable server port
    {ok, SrvSock} = gen_tcp:connect("localhost", 8080, ?TCP_OPTS),
    error_logger:info_msg("[PROXY] Handling connection"),
    Pid = spawn(fun() -> handshake(CliSock, SrvSock, Fun) end),
    ok = gen_tcp:controlling_process(CliSock, Pid),
    ok = gen_tcp:controlling_process(SrvSock, Pid),
    accept(LSock, Fun).

handshake(CliSock, SrvSock, Fun) ->
    %% 
    %% Set both sockets active
    inet:setopts(CliSock, [{active, true}]),
    inet:setopts(SrvSock, [{active, true}]),
    receive
        {tcp, CliSock, Data} ->
            ok = gen_tcp:send(SrvSock, Data),
            {ok, {_ethod, Path, Headers}} = decode_request(Data),
            %% TODO Handle some other error cases
            case lists:keyfind("Sec-Websocket-Key", 1, Headers) of
                false ->
                    error_logger:info_msg("[PROXY] No WS Key found in headers"),
                    handshake(CliSock, SrvSock, Fun);
                {"Sec-Websocket-Key", Key} ->
                    error_logger:info_msg("[PROXY] Client used key ~p", [Key]),
                    WSReq = websocket_req:new(
                              ws, "localhost", 8081,
                              Path, CliSock, gen_tcp,
                              list_to_binary(Key)),
                    validate_handshake(WSReq, CliSock, SrvSock, Fun)
            end
    end.

validate_handshake(WSReq, CliSock, SrvSock, Fun) ->
    receive
        {tcp, SrvSock, Data} ->
            case wsc_lib:validate_handshake(Data, websocket_req:key(WSReq)) of
                {ok, Buf} ->
                    error_logger:info_msg("[PROXY][Server] Confirmed handshake"),
                    ok = gen_tcp:send(CliSock, Data),
                    loop(#{
                      wsreq => WSReq,
                      client => {CliSock, <<>>},
                      server => {SrvSock, Buf},
                      handler => Fun
                     });
                    %loop(WSReq, CliSock, <<>>, SrvSock, Buf, Fun);
                Other ->
                    error_logger:info_msg("[PROXY][Server] failed handshake: ~p", [Other]),
                    {error, Other}
            end
    end.

loop(#{ client := {CliSock, _}, server := {SrvSock, _} }=St0) ->
    %% Set both sockets active
    inet:setopts(CliSock, [{active, true}]),
    inet:setopts(SrvSock, [{active, true}]),
    receive
        {tcp, CliSock, Data} ->
            handle_frame(client, Data, St0);
        {tcp, SrvSock, Data} ->
            handle_frame(server, Data, St0);
        {tcp_closed, CliSock} ->
            error_logger:info_msg("[PROXY][Client:Closed]"),
            gen_tcp:close(SrvSock),
            (catch gen_tcp:close(CliSock)),
            ok;
        {tcp_closed, SrvSock} ->
            error_logger:info_msg("[PROXY][Server:Closed]"),
            gen_tcp:close(CliSock),
            (catch gen_tcp:close(SrvSock)),
            ok
    end.

%% TODO What about the socket reference in WSReq?
handle_frame(Tag, RawData, #{ wsreq := WSReq0 }=St0) 
  when Tag == server ; Tag == client ->
    {Sock, PreBuf, DstSock, _} = pick_socks(Tag, St0),
    case wsc_lib:decode_frame(WSReq0, << PreBuf/binary, RawData/binary >>) of
        {recv, WSReq1, Buffer} -> 
            %% TODO Because we're doing the buffering in the proxy shouldn't we pass
            %% the whole << PreBuf, RawData >> to the handler below?
            loop(St0#{Tag => {Sock, Buffer}, wsreq => WSReq1});
        {frame, {_OpCode, _Payload}, WSReq1, Buffer}=Frame ->
            Fun = maps:get(handler, St0),
            %% TODO Shouldn't we use the full buffered raw data here?
            _ = Fun(Tag, DstSock, RawData, Frame),
            loop(St0#{Tag => {Sock, Buffer}, wsreq => WSReq1});
        {close, Reason, _WSReq1} ->
            error_logger:error_msg("[PROXY] ~p socket closed: ~p", [Tag, Reason]),
            %% TODO Handle closes?
            error
    end.

pick_socks(client, #{ client := {CliSock, CliBuf}, server := {SrvSock, SrvBuf} }) ->
    {CliSock, CliBuf, SrvSock, SrvBuf};
pick_socks(server, #{ client := {CliSock, CliBuf}, server := {SrvSock, SrvBuf} }) ->
    {SrvSock, SrvBuf, CliSock, CliBuf}.

decode_request(Data) ->
    case erlang:decode_packet(http, Data, []) of
        {ok, {http_request, Method, Path, _ersion}, Request} ->
            {ok, Headers} = decode_headers(Request, []),
            {ok, {Method, Path, Headers}};
        Other -> {error, Other}
    end.
decode_headers(Data, Acc) ->
    case erlang:decode_packet(httph, Data, []) of
        {ok, {http_header, _, K, _, V}, Rest} ->
            error_logger:info_msg("[PROXY] Client sent ~p(~p)", [K, V]),
            decode_headers(Rest, [{K, V} | Acc]);
        {ok, http_eoh, <<>>} ->
            {ok, Acc};
        {ok, {http_error, Reason}, Rest} ->
            %% TODO If we hit this, remove the first "\n" from Data and try again
            {error, {http_error, Reason, Rest}}
    end.
