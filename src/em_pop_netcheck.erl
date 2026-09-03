%%%-------------------------------------------------------------------
%%% @doc Blocked-IP classifier for gossip admission hardening.
%%%
%%% Identifies loopback / private / link-local / unique-local addresses
%%% (including cloud metadata 169.254.169.254 and IPv6-embedded IPv4)
%%% so that em_pop_node can refuse gossiped peers pointing at them.
%%% Classifier logic is identical to emquest_safeurl:is_blocked_ip/1.
%%% @end
%%%-------------------------------------------------------------------
-module(em_pop_netcheck).
-export([is_blocked_ip/1, host_blocked/1]).

%% @doc True if HostBin resolves to any blocked address, or cannot be
%% resolved at all (fail closed).
-spec host_blocked(binary()) -> boolean().
host_blocked(Host) when is_binary(Host) ->
    HostStr = binary_to_list(Host),
    A4 = case inet:getaddrs(HostStr, inet)  of {ok, L4} -> L4; _ -> [] end,
    A6 = case inet:getaddrs(HostStr, inet6) of {ok, L6} -> L6; _ -> [] end,
    case A4 ++ A6 of
        []    -> true;
        Addrs -> lists:any(fun is_blocked_ip/1, Addrs)
    end.

%% @doc True for loopback / private / link-local / unique-local addresses.
%% IPv4
-spec is_blocked_ip(inet:ip_address()) -> boolean().
is_blocked_ip({0,_,_,_})       -> true;           %% 0.0.0.0/8
is_blocked_ip({127,_,_,_})     -> true;
is_blocked_ip({10,_,_,_})      -> true;
is_blocked_ip({192,168,_,_})   -> true;
is_blocked_ip({169,254,_,_})   -> true;
is_blocked_ip({172,B,_,_}) when B >= 16, B =< 31 -> true;
is_blocked_ip({100,B,_,_}) when B >= 64, B =< 127 -> true;  %% CGNAT 100.64/10
is_blocked_ip({_,_,_,_})       -> false;
%% IPv6 embedded-IPv4 (mapped ::ffff:0:0/96, compat ::/96, NAT64 64:ff9b::/96)
is_blocked_ip({0,0,0,0,0,16#ffff,G,H}) -> is_blocked_ip(v4_of(G,H));
is_blocked_ip({16#64,16#ff9b,0,0,0,0,G,H}) -> is_blocked_ip(v4_of(G,H));
is_blocked_ip({0,0,0,0,0,0,G,H}) when (G bsl 16) bor H =/= 0,
                                       (G bsl 16) bor H =/= 1 -> is_blocked_ip(v4_of(G,H));
%% IPv6 native
is_blocked_ip({0,0,0,0,0,0,0,1}) -> true;
is_blocked_ip({W,_,_,_,_,_,_,_}) when W >= 16#fe80, W =< 16#febf -> true;
is_blocked_ip({W,_,_,_,_,_,_,_}) when W >= 16#fc00, W =< 16#fdff -> true;
is_blocked_ip({_,_,_,_,_,_,_,_}) -> false.

%% @private embedded IPv4 from the low 32 bits of a mapped/compat/NAT64 address.
v4_of(G, H) -> {G bsr 8, G band 16#ff, H bsr 8, H band 16#ff}.
