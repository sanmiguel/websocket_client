-module(close_codes_client).

-behaviour(websocket_client).

-export(
   [
    init/1,
    onconnect/2,
    ondisconnect/2,
    websocket_handle/3,
    websocket_info/3,
    websocket_terminate/3
   ]).

%% Modes needed for 3 test cases
init([t_client_closes_conn, Pid]) ->
    % Start disconnected
    {ok, {t_client_closes_conn, Pid}}.

onconnect(_WSReq, {t_client_closes_conn, Pid}=St) ->
    Pid ! {self(), connected},
    {ok, St};
onconnect(WSReq, State) ->
    {ok, State}.

ondisconnect(Reason, State) ->
    {ok, State}.

websocket_handle({Type, Payload}, _WSReq, {t_client_closes_conn, Pid}) ->
    Pid ! {self(), Type, Payload},
    {ok, {t_client_closes_conn, Pid}};
websocket_handle({Type, Payload}, WSReq, State) ->
    {ok, State}.

websocket_info(Term, WSReq, State) ->
    {ok, State}.

websocket_terminate(Reason, WSReq, State) ->
    ok.
