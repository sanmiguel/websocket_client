-module(wsc_lib).
%% @author Jeremy Ong
%% @author Michael Coles
%% Purely functional aspects of websocket client comms.
%%
%% Herein live all the functions for pure data processing.
-compile([export_all]).
-include("websocket_req.hrl").

-export([create_auth_header/3]).
-export([create_handshake/2]).
-export([encode_frame/1]).
-export([generate_ws_key/0]).

-export([validate_handshake/2]).
-export([decode_frame/2]).
-export([decode_frame/5]).

-spec create_auth_header(Type :: basic, User :: binary(), Pass :: binary()) ->
    {binary(), binary()}.
create_auth_header(basic, User, Pass) ->
    PlainAuth = << User/binary, ":", Pass/binary >>,
    B64Auth = base64:encode(PlainAuth),
    {<<"Authorization">>, <<"Basic ", B64Auth/binary>>}.

-spec create_handshake(websocket_req:req(), [{string(), string()}]) ->
    iolist().
create_handshake(WSReq, ExtraHeaders) ->
    [Path, Host, Key] = websocket_req:get([path, host, key], WSReq),
    ["GET ", Path, " HTTP/1.1\r\n"
     "Host: ", Host, "\r\n"
     "Connection: Upgrade\r\n"
     "Sec-WebSocket-Version: 13\r\n"
     "Sec-WebSocket-Key: ", Key, "\r\n"
     "Upgrade: websocket\r\n",
     [ [Header, ": ", Value, "\r\n"] || {Header, Value} <- ExtraHeaders],
     "\r\n"].

%% @doc Validate handshake response challenge
-spec validate_handshake(HandshakeResponse :: binary(), Key :: binary()) ->
    {ok, binary()}
    | {notfound, binary()}
    | {error, term()}.
validate_handshake(HandshakeResponse, Key) ->
    case re:run(HandshakeResponse, "\\r\\n\\r\\n") of
        {match, _} ->
            Challenge = base64:encode(
                          crypto:hash(sha, << Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" >>)),
            %% Consume the response...
            {ok, Status, Header, Buffer} = consume_response(HandshakeResponse),
            {_Version, Code, Message} = Status,
            case Code of
                % 101 means Switching Protocol
                101 ->
                    %% ...and make sure the challenge is valid.
                    case proplists:get_value(<<"Sec-Websocket-Accept">>, Header) of
                        Challenge -> {ok, Buffer};
                        _Invalid   -> {error, invalid_handshake}
                    end;
                _ -> {error, {Code, Message}}
            end;
        _ ->
            {notfound, HandshakeResponse}
    end.

%% @doc Consumes the HTTP response and extracts status, header and the body.
consume_response(Response) ->
    {ok, {http_response, Version, Code, Message}, Header} =
        erlang:decode_packet(http_bin, Response, []),
    consume_response({Version, Code, Message}, Header, []).
consume_response(Status, Response, HeaderAcc) ->
    case erlang:decode_packet(httph_bin, Response, []) of
        {ok, {http_header, _Length, Field, _Reserved, Value}, Rest} ->
            consume_response(Status, Rest, [{Field, Value} | HeaderAcc]);
        {ok, http_eoh, Body} ->
            {ok, Status, HeaderAcc, Body}
    end.

unpack_frame(<< Fin:1, RSV:3, OpCode:4, Mask:1, Len:7, Payload/bits >>)
  when Len < 126 ->
    {ok, Fin, RSV, OpCode, Len, unmask_frame(Mask, Len, Payload)};
unpack_frame(<< Fin:1, RSV:3, OpCode:4, Mask:1, 126:7, Len:16, Payload/bits>>)
  when Len > 125, OpCode < 8 ->
    {ok, Fin, RSV, OpCode, Len, unmask_frame(Mask, Len, Payload)};
unpack_frame(<< Fin:1, RSV:3, OpCode:4, Mask:1, 127:7, 0:1, Len:63, Payload/bits>>)
  when Len > 16#ffff, OpCode < 8 ->
    {ok, Fin, RSV, OpCode, Len, unmask_frame(Mask, Len, Payload)};
unpack_frame(Data) ->
    {incomplete, Data}.

%% @doc Start or continue continuation payload with length less than 126 bytes
decode_frame(WSReq, Frame) when is_binary(Frame) ->
    case unpack_frame(Frame) of
        {incomplete, Data} -> {recv, WSReq, Data};
        {ok, 0, 0, OpCode, Len, Payload} ->
            WSReq1 = set_continuation_if_empty(WSReq, OpCode),
            WSReq2 = websocket_req:fin(0, WSReq1),
            decode_frame(WSReq2, OpCode, Len, Payload, <<>>);
        {ok, 1, 0, OpCode, Len, Payload} ->
            WSReq1 = websocket_req:fin(1, WSReq),
            decode_frame(WSReq1, OpCode, Len, Payload, <<>>)
    end.

unmask_frame(0, _, Payload) -> Payload;
unmask_frame(1, Len, << Mask:32, Rest/bits >>) ->
    << Payload:Len/binary, NextFrame/bits >> = Rest,
    << (mask_payload(Mask, Payload))/bits, NextFrame/binary >>.

-spec decode_frame(websocket_req:req(),
               Opcode :: websocket_req:opcode(),
               Len :: non_neg_integer(),
               Data :: binary(),
               Buffer :: binary()) ->
    {recv, websocket_req:req(), IncompleteFrame :: binary()}
    | {frame, {OpcodeName :: atom(), Payload :: binary()},
                   websocket_req:req(), Rest :: binary()}
    | {close, Reason :: term(), websocket_req:req()}.
%% @doc Length known and still missing data
decode_frame(WSReq, Opcode, Len, Data, Buffer)
  when byte_size(Data) < Len ->
    Remaining = Len - byte_size(Data),
    WSReq1 = websocket_req:remaining(Remaining, WSReq),
    WSReq2 = websocket_req:opcode(Opcode, WSReq1),
    {recv, WSReq2, << Buffer/bits, Data/bits >>};
%% @doc Length known and remaining data is appended to the buffer
decode_frame(WSReq, Opcode, Len, Data, Buffer) ->
    [Continuation, ContinuationOpcode] =
        websocket_req:get([continuation, continuation_opcode], WSReq),
    Fin = websocket_req:fin(WSReq),
    << Payload:Len/binary, Rest/bits >> = Data,
    FullPayload = << Buffer/binary, Payload/binary >>,
    OpcodeName = websocket_req:opcode_to_name(Opcode),
    case OpcodeName of
        close when byte_size(FullPayload) >= 2 ->
            << CodeBin:2/binary, ClosePayload/binary >> = FullPayload,
            Code = binary:decode_unsigned(CodeBin),
            Reason = case Code of
                         1000 -> {normal, ClosePayload};
                         1002 -> {error, badframe, ClosePayload};
                         1007 -> {error, badencoding, ClosePayload};
                         1011 -> {error, handler, ClosePayload};
                         _ -> {remote, Code, ClosePayload}
                     end,
            {close, Reason, WSReq};
        close ->
            {close, {remote, <<>>}, WSReq};
        %% Non-control continuation frame
        _ when Opcode < 8, Continuation =/= undefined, Fin == 0 ->
            %% Append to previously existing continuation payloads and continue
            Continuation1 = << Continuation/binary, FullPayload/binary >>,
            WSReq1 = websocket_req:continuation(Continuation1, WSReq),
            decode_frame(WSReq1, Rest);
        %% Terminate continuation frame sequence with non-control frame
        _ when Opcode < 8, Continuation =/= undefined, Fin == 1 ->
            DefragPayload = << Continuation/binary, FullPayload/binary >>,
            WSReq1 = websocket_req:continuation(undefined, WSReq),
            WSReq2 = websocket_req:continuation_opcode(undefined, WSReq1),
            ContinuationOpcodeName = websocket_req:opcode_to_name(ContinuationOpcode),
            {frame, {ContinuationOpcodeName, DefragPayload}, WSReq2, Rest};
        _ ->
            {frame, {OpcodeName, FullPayload}, WSReq, Rest}
    end.

%% @doc Encodes the data with a header (including a masking key) and
%% masks the data
-spec encode_frame(websocket_req:frame()) -> binary().
encode_frame({Type, Payload}) ->
    Opcode = websocket_req:name_to_opcode(Type),
    Len = iolist_size(Payload),
    BinLen = payload_length_to_binary(Len),
    MaskingKeyBin = crypto:strong_rand_bytes(4),
    << MaskingKey:32 >> = MaskingKeyBin,
    Header = << 1:1, 0:3, Opcode:4, 1:1, BinLen/bits, MaskingKeyBin/bits >>,
    MaskedPayload = mask_payload(MaskingKey, Payload),
    << Header/binary, MaskedPayload/binary >>;
encode_frame(Type) when is_atom(Type) ->
    encode_frame({Type, <<>>}).

%% @doc The payload is masked using a masking key byte by byte.
%% Can do it in 4 byte chunks to save time until there is left than 4 bytes left
mask_payload(MaskingKey, Payload) when is_integer(MaskingKey), is_binary(Payload) ->
    mask_payload(MaskingKey, Payload, <<>>).
mask_payload(_, <<>>, Acc) ->
    Acc;
mask_payload(MaskingKey, << D:32, Rest/bits >>, Acc) ->
    T = D bxor MaskingKey,
    mask_payload(MaskingKey, Rest, << Acc/binary, T:32 >>);
mask_payload(MaskingKey, << D:24 >>, Acc) ->
    << MaskingKeyPart:24, _:8 >> = << MaskingKey:32 >>,
    T = D bxor MaskingKeyPart,
    << Acc/binary, T:24 >>;
mask_payload(MaskingKey, << D:16 >>, Acc) ->
    << MaskingKeyPart:16, _:16 >> = << MaskingKey:32 >>,
    T = D bxor MaskingKeyPart,
    << Acc/binary, T:16 >>;
mask_payload(MaskingKey, << D:8 >>, Acc) ->
    << MaskingKeyPart:8, _:24 >> = << MaskingKey:32 >>,
    T = D bxor MaskingKeyPart,
    << Acc/binary, T:8 >>.

%% @doc Encode the payload length as binary in a variable number of bits.
%% See RFC Doc for more details
payload_length_to_binary(Len) when Len =<125 ->
    << Len:7 >>;
payload_length_to_binary(Len) when Len =< 16#ffff ->
    << 126:7, Len:16 >>;
payload_length_to_binary(Len) when Len =< 16#7fffffffffffffff ->
    << 127:7, Len:64 >>.

%% @doc If this is the first continuation frame, set the opcode and initialize
%% continuation to an empty binary. Otherwise, return the request object untouched.
-spec set_continuation_if_empty(WSReq :: websocket_req:req(),
                                Opcode :: websocket_req:opcode()) ->
                                       websocket_req:req().
set_continuation_if_empty(WSReq, Opcode) ->
    case websocket_req:continuation(WSReq) of
        undefined ->
            WSReq1 = websocket_req:continuation_opcode(Opcode, WSReq),
            websocket_req:continuation(<<>>, WSReq1);
        _ ->
            WSReq
    end.

%% @doc Key sent in initial handshake
-spec generate_ws_key() -> binary().
generate_ws_key() ->
    base64:encode(crypto:strong_rand_bytes(16)).
