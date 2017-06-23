-module(echo_proxy).

-export([listen/0]).
%% A single process that waits to receive an inbound connection on
%% port 8081. Upon receipt of connection, it makes an outbound connection
%% to port 8080 and forwards all traffic back and forth.
%%
%% TODO: Filter according to ~rules
%%

-define(TCP_OPTS,
        [binary, {active, false}, {packet, 0}, {reuseaddr, true}]).
listen() ->
    {ok, LSock} = gen_tcp:listen(8081, ?TCP_OPTS),
    accept(LSock).

accept(LSock) ->
    {ok, Sock} = gen_tcp:accept(LSock),
    {ok, OutSock} = gen_tcp:connect("localhost", 8080, ?TCP_OPTS),
    error_logger:info_msg("Handling connection"),
    Pid = spawn(fun() -> handshake(Sock, OutSock) end),
    ok = gen_tcp:controlling_process(Sock, Pid),
    ok = gen_tcp:controlling_process(OutSock, Pid),
    accept(LSock).

handshake(InSock, OutSock) ->
    %% 
    %% Set both sockets active
    inet:setopts(InSock, [{active, true}]),
    inet:setopts(OutSock, [{active, true}]),
    receive
        {tcp, InSock, Data} ->
            ok = gen_tcp:send(OutSock, Data),
            {ok, {_ethod, Path, Headers}} = decode_request(Data),
            %% TODO Handle some other error cases
            case lists:keyfind("Sec-Websocket-Key", 1, Headers) of
                false ->
                    error_logger:info_msg("No WS Key found in headers"),
                    handshake(InSock, OutSock);
                {"Sec-Websocket-Key", Key} ->
                    error_logger:info_msg("Client used key ~p", [Key]),
                    WSReq = websocket_req:new(
                              ws, "localhost", 8081,
                              Path, InSock, gen_tcp,
                              list_to_binary(Key)),
                    validate_handshake(WSReq, InSock, OutSock)
            end
    end.

validate_handshake(WSReq, InSock, OutSock) ->
    receive
        {tcp, OutSock, Data} ->
            case wsc_lib:validate_handshake(Data, websocket_req:key(WSReq)) of
                {ok, _} ->
                    error_logger:info_msg("[Server] Confirmed handshake"),
                    ok = gen_tcp:send(InSock, Data),
                    loop(WSReq, InSock, OutSock);
                Other ->
                    error_logger:info_msg("[Server] failed handshake: ~p", [Other]),
                    {error, Other}
            end
    end.

%% TODO Processing frames go here
handle_frame("Server", _, _, {frame, {pong, Foo}, _, <<>>}) ->
    error_logger:info_msg("[Server] {pong, ~s} BLOCKED", [Foo]),
    ok;
handle_frame(Name, DstSock, RawData, {frame, Decoded, _, Rest}) ->
    error_logger:info_msg("[~s]: ~p ~p~n", [Name, Decoded, Rest]),
    gen_tcp:send(DstSock, RawData).

loop(WSReq, InSock, OutSock) ->
    %% 
    %% Set both sockets active
    inet:setopts(InSock, [{active, true}]),
    inet:setopts(OutSock, [{active, true}]),
    receive
        {tcp, InSock, Data} ->
            handle_frame("Client", OutSock, Data, wsc_lib:decode_frame(WSReq, Data)),
            loop(WSReq, InSock, OutSock);
        {tcp, OutSock, Data} ->
            handle_frame("Server", InSock, Data, wsc_lib:decode_frame(WSReq, Data)),
            loop(WSReq, InSock, OutSock);
        {tcp_closed, InSock} ->
            error_logger:info_msg("[Client:Closed]"),
            gen_tcp:close(OutSock),
            (catch gen_tcp:close(InSock)),
            ok;
        {tcp_closed, OutSock} ->
            error_logger:info_msg("[Server:Closed]"),
            gen_tcp:close(InSock),
            (catch gen_tcp:close(OutSock)),
            ok
    end.

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
            error_logger:info_msg("Client sent ~p(~p)", [K, V]),
            decode_headers(Rest, [{K, V} | Acc]);
        {ok, http_eoh, <<>>} ->
            {ok, Acc};
        {ok, {http_error, Reason}, Rest} ->
            %% TODO If we hit this, remove the first "\n" from Data and try again
            {error, {http_error, Reason, Rest}}
    end.



