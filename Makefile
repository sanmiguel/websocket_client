SHELL := /bin/bash
PROJECT = websocket_client

TEST_DEPS = cowboy recon
CT_SUITES = wc

include erlang.mk
