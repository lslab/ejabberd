%%%----------------------------------------------------------------------
%%% File    : mod_carboncopy.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : Message Carbons XEP-0280 0.8
%%% Created : 5 May 2008 by Mickael Remond <mremond@process-one.net>
%%% Usage   : Add the following line in modules section of ejabberd.yml:
%%%              {mod_carboncopy, []}
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------
-module (mod_carboncopy).

-author ('ecestari@process-one.net').
-protocol({xep, 280, '0.8'}).

-behavior(gen_mod).

%% API:
-export([start/2,
         stop/1]).

-export([user_send_packet/4, user_receive_packet/5,
	 iq_handler2/3, iq_handler1/3, remove_connection/4,
	 is_carbon_copy/1, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-define(PROCNAME, ?MODULE).

-callback init(binary(), gen_mod:opts()) -> any().
-callback enable(binary(), binary(), binary(), binary()) -> ok | {error, any()}.
-callback disable(binary(), binary(), binary()) -> ok | {error, any()}.
-callback list(binary(), binary()) -> [{binary(), binary()}].

is_carbon_copy(Packet) ->
    is_carbon_copy(Packet, <<"sent">>) orelse
	is_carbon_copy(Packet, <<"received">>).

is_carbon_copy(Packet, Direction) ->
    case fxml:get_subtag(Packet, Direction) of
	#xmlel{name = Direction, attrs = Attrs} ->
	    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
		?NS_CARBONS_2 -> true;
		?NS_CARBONS_1 -> true;
		_ -> false
	    end;
	_ -> false
    end.

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts,fun gen_iq_handler:check_type/1, one_queue),
    mod_disco:register_feature(Host, ?NS_CARBONS_1),
    mod_disco:register_feature(Host, ?NS_CARBONS_2),
    Mod = gen_mod:db_mod(Host, ?MODULE),
    Mod:init(Host, Opts),
    ejabberd_hooks:add(unset_presence_hook,Host, ?MODULE, remove_connection, 10),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:add(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:add(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_CARBONS_2, ?MODULE, iq_handler2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_CARBONS_1, ?MODULE, iq_handler1, IQDisc).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_CARBONS_1),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_CARBONS_2),
    mod_disco:unregister_feature(Host, ?NS_CARBONS_2),
    mod_disco:unregister_feature(Host, ?NS_CARBONS_1),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:delete(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:delete(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    ejabberd_hooks:delete(unset_presence_hook,Host, ?MODULE, remove_connection, 10).

iq_handler2(From, To, IQ) ->
	iq_handler(From, To, IQ, ?NS_CARBONS_2).
iq_handler1(From, To, IQ) ->
	iq_handler(From, To, IQ, ?NS_CARBONS_1).

iq_handler(From, _To,
	   #iq{type=set, lang = Lang,
	       sub_el = #xmlel{name = Operation} = SubEl} = IQ, CC)->
    ?DEBUG("carbons IQ received: ~p", [IQ]),
    {U, S, R} = jid:tolower(From),
    Result = case Operation of
        <<"enable">>->
	    ?INFO_MSG("carbons enabled for user ~s@~s/~s", [U,S,R]),
            enable(S,U,R,CC);
        <<"disable">>->
	    ?INFO_MSG("carbons disabled for user ~s@~s/~s", [U,S,R]),
            disable(S, U, R)
    end,
    case Result of
        ok ->
	    ?DEBUG("carbons IQ result: ok", []),
            IQ#iq{type=result, sub_el=[]};
	{error,_Error} ->
	    ?ERROR_MSG("Error enabling / disabling carbons: ~p", [Result]),
	    Txt = <<"Database failure">>,
            IQ#iq{type=error,sub_el = [SubEl, ?ERRT_INTERNAL_SERVER_ERROR(Lang, Txt)]}
    end;

iq_handler(_From, _To, #iq{lang = Lang, sub_el = SubEl} = IQ, _CC)->
    Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
    IQ#iq{type=error, sub_el = [SubEl, ?ERRT_NOT_ALLOWED(Lang, Txt)]}.

user_send_packet(Packet, _C2SState, From, To) ->
    check_and_forward(From, To, Packet, sent).

user_receive_packet(Packet, _C2SState, JID, _From, To) ->
    check_and_forward(JID, To, Packet, received).

% Modified from original version:
%    - registered to the user_send_packet hook, to be called only once even for multicast
%    - do not support "private" message mode, and do not modify the original packet in any way
%    - we also replicate "read" notifications
check_and_forward(JID, To, Packet, Direction)->
    case is_chat_message(Packet) andalso
	     fxml:get_subtag(Packet, <<"private">>) == false andalso
		 fxml:get_subtag(Packet, <<"no-copy">>) == false of
	true ->
	    case is_carbon_copy(Packet) of
		false ->
		    send_copies(JID, To, Packet, Direction),
		    Packet;
		true ->
		    %% stop the hook chain, we don't want logging modules to duplicates
		    %% this message
		    {stop, Packet}
	    end;
        _ ->
	    Packet
    end.

remove_connection(User, Server, Resource, _Status)->
    disable(Server, User, Resource),
    ok.


%%% Internal
%% Direction = received | sent <received xmlns='urn:xmpp:carbons:1'/>
send_copies(JID, To, Packet, Direction)->
    {U, S, R} = jid:tolower(JID),
    PrioRes = ejabberd_sm:get_user_present_resources(U, S),
    {_, AvailRs} = lists:unzip(PrioRes),
    {MaxPrio, MaxRes} = case catch lists:max(PrioRes) of
	{Prio, Res} -> {Prio, Res};
	_ -> {0, undefined}
    end,

    %% unavailable resources are handled like bare JIDs
    IsBareTo = case {Direction, To} of
	{received, #jid{lresource = <<>>}} -> true;
	{received, #jid{lresource = LRes}} -> not lists:member(LRes, AvailRs);
	_ -> false
    end,
    %% list of JIDs that should receive a carbon copy of this message (excluding the
    %% receiver(s) of the original message
    TargetJIDs = case {IsBareTo, R} of
	{true, MaxRes} ->
	    OrigTo = fun(Res) -> lists:member({MaxPrio, Res}, PrioRes) end,
	    [ {jid:make({U, S, CCRes}), CC_Version}
	     || {CCRes, CC_Version} <- list(U, S),
		lists:member(CCRes, AvailRs), not OrigTo(CCRes) ];
	{true, _} ->
	    %% The message was sent to our bare JID, and we currently have
	    %% multiple resources with the same highest priority, so the session
	    %% manager routes the message to each of them. We create carbon
	    %% copies only from one of those resources (the one where R equals
	    %% MaxRes) in order to avoid duplicates.
	    [];
	{false, _} ->
	    [ {jid:make({U, S, CCRes}), CC_Version}
	     || {CCRes, CC_Version} <- list(U, S),
		lists:member(CCRes, AvailRs), CCRes /= R ]
	    %TargetJIDs = lists:delete(JID, [ jid:make({U, S, CCRes}) || CCRes <- list(U, S) ]),
    end,

    lists:map(fun({Dest,Version}) ->
		    {_, _, Resource} = jid:tolower(Dest),
		    ?DEBUG("Sending:  ~p =/= ~p", [R, Resource]),
		    Sender = jid:make({U, S, <<>>}),
		    %{xmlelement, N, A, C} = Packet,
		    New = build_forward_packet(JID, Packet, Sender, Dest, Direction, Version),
		    ejabberd_router:route(Sender, Dest, New)
	      end, TargetJIDs),
    ok.

build_forward_packet(JID, Packet, Sender, Dest, Direction, ?NS_CARBONS_2) ->
    #xmlel{name = <<"message">>,
	   attrs = [{<<"xmlns">>, <<"jabber:client">>},
		    {<<"type">>, message_type(Packet)},
		    {<<"from">>, jid:to_string(Sender)},
		    {<<"to">>, jid:to_string(Dest)}],
	   children = [
		#xmlel{name = list_to_binary(atom_to_list(Direction)),
		       attrs = [{<<"xmlns">>, ?NS_CARBONS_2}],
		       children = [
			#xmlel{name = <<"forwarded">>,
			       attrs = [{<<"xmlns">>, ?NS_FORWARD}],
			       children = [
				complete_packet(JID, Packet, Direction)]}
		]}
	   ]};
build_forward_packet(JID, Packet, Sender, Dest, Direction, ?NS_CARBONS_1) ->
    #xmlel{name = <<"message">>,
	   attrs = [{<<"xmlns">>, <<"jabber:client">>},
		    {<<"type">>, message_type(Packet)},
		    {<<"from">>, jid:to_string(Sender)},
		    {<<"to">>, jid:to_string(Dest)}],
	   children = [
		#xmlel{name = list_to_binary(atom_to_list(Direction)),
			attrs = [{<<"xmlns">>, ?NS_CARBONS_1}]},
		#xmlel{name = <<"forwarded">>,
		       attrs = [{<<"xmlns">>, ?NS_FORWARD}],
		       children = [complete_packet(JID, Packet, Direction)]}
		]}.


enable(Host, U, R, CC)->
    ?DEBUG("enabling for ~p", [U]),
    Mod = gen_mod:db_mod(Host, ?MODULE),
    Mod:enable(U, Host, R, CC).

disable(Host, U, R)->
    ?DEBUG("disabling for ~p", [U]),
    Mod = gen_mod:db_mod(Host, ?MODULE),
    Mod:disable(U, Host, R).

complete_packet(From, #xmlel{name = <<"message">>, attrs = OrigAttrs} = Packet, sent) ->
    %% if this is a packet sent by user on this host, then Packet doesn't
    %% include the 'from' attribute. We must add it.
    Attrs = lists:keystore(<<"xmlns">>, 1, OrigAttrs, {<<"xmlns">>, <<"jabber:client">>}),
    case proplists:get_value(<<"from">>, Attrs) of
	undefined ->
		Packet#xmlel{attrs = [{<<"from">>, jid:to_string(From)}|Attrs]};
	_ ->
		Packet#xmlel{attrs = Attrs}
    end;
complete_packet(_From, #xmlel{name = <<"message">>, attrs=OrigAttrs} = Packet, received) ->
    Attrs = lists:keystore(<<"xmlns">>, 1, OrigAttrs, {<<"xmlns">>, <<"jabber:client">>}),
    Packet#xmlel{attrs = Attrs}.

message_type(#xmlel{attrs = Attrs}) ->
    case fxml:get_attr(<<"type">>, Attrs) of
	{value, Type} -> Type;
	false -> <<"normal">>
    end.

is_chat_message(#xmlel{name = <<"message">>} = Packet) ->
    case message_type(Packet) of
	<<"chat">> -> true;
	<<"normal">> -> has_non_empty_body(Packet);
	_ -> false
    end;
is_chat_message(_Packet) -> false.

has_non_empty_body(Packet) ->
    fxml:get_subtag_cdata(Packet, <<"body">>) =/= <<"">>.

%% list {resource, cc_version} with carbons enabled for given user and host
list(User, Server) ->
    Mod = gen_mod:db_mod(Server, ?MODULE),
    Mod:list(User, Server).

mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
mod_opt_type(_) -> [db_type, iqdisc].
