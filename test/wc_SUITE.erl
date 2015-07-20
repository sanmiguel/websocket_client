-module(wc_SUITE).

-include_lib("common_test/include/ct.hrl").
-define(print(Value), io:format("~n~p~n", [Value])).

-export([
         all/0,
         init_per_suite/1,
         end_per_suite/1
        ]).
-export([
         test_text_frames/1,
         test_binary_frames/1,
         test_control_frames/1,
         test_quick_response/1,
         test_bad_request/1
        ]).

all() ->
    [
     test_text_frames,
     test_binary_frames,
     test_control_frames,
     test_quick_response,
     test_bad_request
    ].

init_per_suite(Config) ->
    ok = application:start(sasl),
    ok = application:start(asn1),
    ok = crypto:start(),
    ok = application:start(public_key),
    ok = application:start(ssl),
    ok = application:start(cowlib),
    ok = application:start(ranch),
    ok = application:start(cowboy),
    {ok,_} = echo_server:start(),
    Config.

end_per_suite(Config) ->
    Config.

test_text_frames(_) ->
    {ok, Pid} = ws_client:start_link(),
    receive {ok, Pid} -> ok after 5000 -> recv_timeout end,
    %% Short message
    Short = short_msg(),
    ws_client:send_text(Pid, Short),
    {text, Short} = ws_client:recv(Pid),
    ok = ws_client:sync_send_text(Pid, Short),
    {text, Short} = ws_client:recv(Pid),
    %% Payload length greater than 125 (actual 150).
    Medium = medium_msg(),
    ws_client:send_text(Pid, Medium),
    {text, Medium} = ws_client:recv(Pid),

    %% Now check that websocket_client:send is working
    ok = websocket_client:send(Pid, {text, Medium}),
    {text, Medium} = ws_client:recv(Pid),

    %% Payload length greater than 65535
    Long = long_msg(),
    ws_client:send_text(Pid, Long),
    {text, Long} = ws_client:recv(Pid),
    ws_client:stop(Pid),
    ok.

test_binary_frames(_) ->
    {ok, Pid} = ws_client:start_link(),
    receive {ok, Pid} -> ok after 5000 -> recv_timeout end,
    %% Short message
    Short = short_msg(),
    ws_client:send_binary(Pid, Short),
    {binary, Short} = ws_client:recv(Pid),
    %% Payload length greater than 125 (actual 150).
    Medium = medium_msg(),
    ws_client:send_binary(Pid, Medium),
    {binary, Medium} = ws_client:recv(Pid),
    %% Payload length greater than 65535
    Long = long_msg(),
    ws_client:send_binary(Pid, Long),
    {binary, Long} = ws_client:recv(Pid),
    ws_client:stop(Pid),
    ok.

test_control_frames(_) ->
    {ok, Pid} = ws_client:start_link(),
    receive {ok, Pid} -> ok after 5000 -> recv_timeout end,
    %% Send ping with short message
    Short = short_msg(),
    ok = ws_client:sync_send_ping(Pid, Short),
    %% Send ping without message
    %ok = ws_client:sync_send_ping(Pid, <<>>),
    {pong, Short} = ws_client:recv(Pid),
    %% Server will echo the ping as well
    {ping, Short} = ws_client:recv(Pid),
    %% to which we will reply automatically
    %% resulting in further pong
    {pong, Short} = ws_client:recv(Pid),
    ok = ws_client:sync_send_ping(Pid, <<>>),
    {pong, <<>>} = ws_client:recv(Pid),
    {ping, <<>>} = ws_client:recv(Pid),
    {pong, <<>>} = ws_client:recv(Pid),
    ws_client:stop(Pid),
    ok.

test_quick_response(_) ->
    %% Connect to the server and...
    {ok, Pid} = ws_client:start_link("ws://localhost:8080/hello/?q=world!"),
    receive {ok, Pid} -> ok after 5000 -> recv_timeout end,
    %% ...make sure we receive the first frame.
    {text, <<"world!">>} = ws_client:recv(Pid, 500),
    ws_client:stop(Pid),
    %% Also, make sure the HTTP response is parsed correctly.
    {ok, Pid2} = ws_client:start_link("ws://localhost:8080/hello/?q=Hello%0D%0A%0D%0AWorld%0D%0A%0D%0A!"),
    receive {ok, Pid2} -> ok after 5000 -> recv_timeout end,
    {text, <<"Hello\r\n\r\nWorld\r\n\r\n!">>} = ws_client:recv(Pid2, 500),
    ws_client:stop(Pid2),
    ok.

test_bad_request(_) ->
    %% Since this is now a real OTP Special Process, we need to trap exits to
    %% receive the error reason properly
    process_flag(trap_exit, true),
    %% Connect to the server and wait for a error
    %% Don't forget this behaviour is largely controlled by the handler
    %% A different handler might just reconnect, but this one terminates.
    {ok, Pid400} =  ws_client:start_link("ws://localhost:8080/hello/?code=400"),
    receive
        {'EXIT', Pid400, {error, {400, <<"Bad Request">>}} } ->
            ok
    after 1000 ->
              ct:fail(timeout)
    end,
    {ok, Pid403} =  ws_client:start_link("ws://localhost:8080/hello/?code=403"),
    receive
        {'EXIT', Pid403, {error, {403, <<"Forbidden">>}}} ->
            ok
    after 1000 ->
              ct:fail(timeout)
    end.

short_msg() ->
    <<"hello">>.
medium_msg() ->
    <<"ttttttttttttttttttttttttt"
      "ttttttttttttttttttttttttt"
      "ttttttttttttttttttttttttt"
      "ttttttttttttttttttttttttt"
      "ttttttttttttttttttttttttt"
      "ttttttttttttttttttttttttt">>.
long_msg() ->
    Medium = medium_msg(),
    %% 600 bytes
    L = << Medium/binary, Medium/binary, Medium/binary, Medium/binary >>,
    %% 2400 bytes
    L1 = << L/binary, L/binary, L/binary, L/binary >>,
    %% 9600 bytes
    L2 = << L1/binary, L1/binary, L1/binary, L1/binary >>,
    %% 38400 bytes
    L3 = << L2/binary, L2/binary, L2/binary, L2/binary >>,
    %% 76800 bytes
    << L3/binary, L3/binary >>.

%%% 4-bit integer 0-F
%%% 3-7, B-F unsupported
%control_opcode() ->
%    oneof([
%        16#8, % connection close
%        16#9, % ping
%        16#A  % pong
%      ]).
%noncontrol_opcode() -> 
%    oneof([
%        16#0, % continuation
%        16#1, % test frame
%        16#2  % binary frame
%    ]).
%
%opcode() ->
%    oneof([control_opcode(), noncontrol_opcode()]).
%
%websocket_frame() ->
%    %   0                   1                   2                   3
%    %   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%    %  +-+-+-+-+-------+-+-------------+-------------------------------+
%    %  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
%    %  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
%    %  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
%    %  | |1|2|3|       |K|             |                               |
%    %  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
%    %  |     Extended payload length continued, if payload len == 127  |
%    %  + - - - - - - - - - - - - - - - +-------------------------------+
%    %  |                               |Masking-key, if MASK set to 1  |
%    %  +-------------------------------+-------------------------------+
%    %  | Masking-key (continued)       |          Payload Data         |
%    %  +-------------------------------- - - - - - - - - - - - - - - - +
%    %  :                     Payload Data continued ...                :
%    %  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
%    %  |                     Payload Data continued ...                |
%    %  +---------------------------------------------------------------+
%    Fin  = 1, %% Single frame
%    RSV  = 0, %% Extensions unsupported
%    Masked = 1, %% Masking required
%    %% Extensions as-yet unsupported
%    OpCode = opcode(),
%    << Fin:1, RSV:3, OpCode:4, Masked:1, 126:7, Len:16, Key:32, Rest:Len/bits >>,
%    << Fin:1, RSV:3, OpCode:4, Masked:1, 127:7, 0:1, Len:63, Key:32, Rest:Len/bits >>,
%    << Fin:1, RSV:3, OpCode:4, Masked:1, Len:7, Key:32, Rest:Len/bits >>.
%
%% Control frames cannot be fragments
%% Non-control frames may be fragmented
%
%
%
%   %  ws-frame                = frame-fin           ; 1 bit in length
%   %                            frame-rsv1          ; 1 bit in length
%   %                            frame-rsv2          ; 1 bit in length
%   %                            frame-rsv3          ; 1 bit in length
%   %                            frame-opcode        ; 4 bits in length
%   %                            frame-masked        ; 1 bit in length
%   %                            frame-payload-length   ; either 7, 7+16,
%   %                                                   ; or 7+64 bits in
%   %                                                   ; length
%   %                            [ frame-masking-key ]  ; 32 bits in length
%   %                            frame-payload-data     ; n*8 bits in
%   %                                                   ; length, where
%   %                                                   ; n >= 0
%
%   %  frame-fin               = %x0 ; more frames of this message follow
%   %                          / %x1 ; final frame of this message
%   %                                ; 1 bit in length
%
%   %  frame-rsv1              = %x0 / %x1
%   %                            ; 1 bit in length, MUST be 0 unless
%   %                            ; negotiated otherwise
%
%   %  frame-rsv2              = %x0 / %x1
%   %                            ; 1 bit in length, MUST be 0 unless
%   %                            ; negotiated otherwise
%
%   %  frame-rsv3              = %x0 / %x1
%   %                            ; 1 bit in length, MUST be 0 unless
%   %                            ; negotiated otherwise
%
%   %  frame-opcode            = frame-opcode-non-control /
%   %                            frame-opcode-control /
%   %                            frame-opcode-cont
%
%   %  frame-opcode-cont       = %x0 ; frame continuation
%
%   %  frame-opcode-non-control= %x1 ; text frame
%   %                          / %x2 ; binary frame
%   %                          / %x3-7
%   %                          ; 4 bits in length,
%   %                          ; reserved for further non-control frames
%
%   %  frame-opcode-control    = %x8 ; connection close
%   %                          / %x9 ; ping
%   %                          / %xA ; pong
%   %                          / %xB-F ; reserved for further control
%   %                                  ; frames
%   %                                  ; 4 bits in length
%   %  
%   % frame-masked            = %x0
%   %                         ; frame is not masked, no frame-masking-key
%   %                         / %x1
%   %                         ; frame is masked, frame-masking-key present
%   %                         ; 1 bit in length
%
%   % frame-payload-length    = ( %x00-7D )
%   %                         / ( %x7E frame-payload-length-16 )
%   %                         / ( %x7F frame-payload-length-63 )
%   %                         ; 7, 7+16, or 7+64 bits in length,
%   %                         ; respectively
%
%   % frame-payload-length-16 = %x0000-FFFF ; 16 bits in length
%
%   % frame-payload-length-63 = %x0000000000000000-7FFFFFFFFFFFFFFF
%   %                         ; 64 bits in length
%
%   % frame-masking-key       = 4( %x00-FF )
%   %                           ; present only if frame-masked is 1
%   %                           ; 32 bits in length
%
%   % frame-payload-data      = (frame-masked-extension-data
%   %                            frame-masked-application-data)
%   %                         ; when frame-masked is 1
%   %                           / (frame-unmasked-extension-data
%   %                             frame-unmasked-application-data)
%   %                         ; when frame-masked is 0
%
%   % frame-masked-extension-data     = *( %x00-FF )
%   %                         ; reserved for future extensibility
%   %                         ; n*8 bits in length, where n >= 0
%
%   % frame-masked-application-data   = *( %x00-FF )
%   %                         ; n*8 bits in length, where n >= 0
%
%   % frame-unmasked-extension-data   = *( %x00-FF )
%   %                         ; reserved for future extensibility
%   %                         ; n*8 bits in length, where n >= 0
%
%   % frame-unmasked-application-data = *( %x00-FF )
%   %                         ; n*8 bits in length, where n >= 0
