-module(close_codes_SUITE).

-export([all/0,
         suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([
         t_client_closes_conn/1,
         t_server_closes_conn/1,
         t_server_closes_sock/1
        ]).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
     t_client_closes_conn,
     t_server_closes_conn,
     t_server_closes_conn
    ].

suite() ->
    [{ct_hooks,[cth_surefire]}, {timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    {ok, Apps} = application:ensure_all_started(cowboy),
    echo_server:start(),
    [{apps, Apps} | Config].
end_per_suite(Config) ->
    echo_server:stop(),
    Apps = ?config(apps, Config),
    [ ok = application:stop(A) || A <- lists:reverse(Apps) ],
    ok.

init_per_testcase(_TestCase, Config) -> Config.
end_per_testcase(_TestCase, _Config) -> ok.

% Test case: Client initiates close sequence
% Client send close frame
% Wait for server close frame but refuse further data sending
% Ensure socket is closed before calling 'ondisconnect'
t_client_closes_conn(_Config) ->
    {ok, C} = websocket_client:start_link(
                echo_server:url(),
                close_codes_client,
                [t_client_closes_conn, self()]),
    %% TODO Turn off keepalives for now
    ok = gen_fsm:send_event(C, connect),
    receive {C, connected} -> ok
    after 5000 -> ct:fail(connection_timeout) end,
    % Send some data
    ok = websocket_client:send(C, {text, <<"t_client_closes_conn">>}),
    % Expect it back
    receive {C, text, <<"t_client_closes_con">>} -> ok
    after 5000 -> ct:fail(initial_data_echo_failed) end.
    % Trigger a close
    % Ensure that the socket gets cleanly closed and the client
    % returns to an idle, disconnected state and can be reconnected and reused.
    % Perhaps this could be repeated a random number of times


% Test case: Server initiates close sequence
% Server sends close frame
% Client responds immediately
% Client awaits socket close, refuses further data sending
% Ensure socket is closed before calling 'ondisconnect'
t_server_closes_conn(_Config) -> ct:fail(unimplemented).

% Test case: server uncleanly closes socket without sending close frames
% Ensure the client doesn't pretend to be able to send data
% Ensure client is able to cleanly close down and reconnect
t_server_closes_sock(_Config) -> ct:fail(unimplemented).
