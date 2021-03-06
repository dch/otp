%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2011. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%

%%% Description: Reading and writing of PEM type encoded files.
%% PEM encoded files have the following structure:
%%
%%	<text>
%%	-----BEGIN SOMETHING-----<CR><LF>
%%	<Base64 encoding line><CR><LF>
%%	<Base64 encoding line><CR><LF>
%%	...
%%	-----END SOMETHING-----<CR><LF>
%%	<text>
%%
%% A file can contain several BEGIN/END blocks. Text lines between
%% blocks are ignored.
%%
%% The encoding is divided into lines separated by <NL>, and each line
%% is precisely 64 characters long (excluding the <NL> characters,
%% except the last line which 64 characters long or shorter. <NL> may
%% follow the last line.

-module(pubkey_pem).

-include("public_key.hrl").

-export([encode/1, decode/1, decipher/2, cipher/3]).
%% Backwards compatibility
-export([decode_key/2]).

-define(ENCODED_LINE_LENGTH, 64).

%%====================================================================
%% Internal application API
%%====================================================================

%%--------------------------------------------------------------------
-spec decode(binary()) -> [pem_entry()].
%%
%% Description: Decodes a PEM binary.
%%--------------------------------------------------------------------		    
decode(Bin) ->
    decode_pem_entries(split_bin(Bin), []).

%%--------------------------------------------------------------------
-spec encode([pem_entry()]) -> iolist().
%%
%% Description: Encodes a list of PEM entries.
%%--------------------------------------------------------------------		    
encode(PemEntries) ->
    encode_pem_entries(PemEntries).

%%--------------------------------------------------------------------
-spec decipher({pki_asn1_type(), decrypt_der(),{Cipher :: string(), Salt :: binary()}}, string()) ->  
		      der_encoded().
%%
%% Description: Deciphers a decrypted pem entry.
%%--------------------------------------------------------------------
decipher({_, DecryptDer, {Cipher,Salt}}, Password) ->
    decode_key(DecryptDer, Password, Cipher, Salt).	

%%--------------------------------------------------------------------
-spec cipher(der_encoded(),{Cipher :: string(), Salt :: binary()} , string()) -> binary().
%%
%% Description: Ciphers a PEM entry
%%--------------------------------------------------------------------
cipher(Der, {Cipher,Salt}, Password)->
    encode_key(Der, Password, Cipher, Salt).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
encode_pem_entries(Entries) ->
    [encode_pem_entry(Entry) || Entry <- Entries].

encode_pem_entry({Asn1Type, Der, not_encrypted}) ->
    StartStr = pem_start(Asn1Type),
    [StartStr, "\n", b64encode_and_split(Der), "\n", pem_end(StartStr) ,"\n\n"];
encode_pem_entry({Asn1Type, Der, {Cipher, Salt}}) ->
    StartStr = pem_start(Asn1Type),
    [StartStr,"\n", pem_decrypt(),"\n", pem_decrypt_info(Cipher, Salt),"\n",
     b64encode_and_split(Der), "\n", pem_end(StartStr) ,"\n\n"].

decode_pem_entries([], Entries) ->
    lists:reverse(Entries);
decode_pem_entries([<<>>], Entries) ->
   lists:reverse(Entries);
decode_pem_entries([<<>> | Lines], Entries) ->
    decode_pem_entries(Lines, Entries);
decode_pem_entries([Start| Lines], Entries) ->
    case pem_end(Start) of
	undefined ->
	    decode_pem_entries(Lines, Entries);
	_End ->
	    {Entry, RestLines} = join_entry(Lines, []),
	    decode_pem_entries(RestLines, [decode_pem_entry(Start, Entry) | Entries])
    end.

decode_pem_entry(Start, [<<"Proc-Type: 4,ENCRYPTED", _/binary>>, Line | Lines]) ->
    Asn1Type = asn1_type(Start),
    Cs = erlang:iolist_to_binary(Lines),
    Decoded = base64:mime_decode(Cs),
    [_, DekInfo0] = string:tokens(binary_to_list(Line), ": "),
    [Cipher, Salt] = string:tokens(DekInfo0, ","), 
    {Asn1Type, Decoded, {Cipher, unhex(Salt)}};
decode_pem_entry(Start, Lines) ->
    Asn1Type = asn1_type(Start),
    Cs = erlang:iolist_to_binary(Lines),
    Der = base64:mime_decode(Cs),
    {Asn1Type, Der, not_encrypted}.
    
split_bin(Bin) ->
    split_bin(0, Bin).

split_bin(N, Bin) ->
    case Bin of
	<<Line:N/binary, "\r\n", Rest/binary>> ->
	    [Line | split_bin(0, Rest)];
	<<Line:N/binary, "\n", Rest/binary>> ->
	    [Line | split_bin(0, Rest)];
	<<Line:N/binary>> ->
	    [Line];
	_ ->
	    split_bin(N+1, Bin)
    end.

b64encode_and_split(Bin) ->
    split_lines(base64:encode(Bin)).

split_lines(<<Text:?ENCODED_LINE_LENGTH/binary>>) ->
    [Text];
split_lines(<<Text:?ENCODED_LINE_LENGTH/binary, Rest/binary>>) ->
    [Text, $\n | split_lines(Rest)];
split_lines(Bin) ->
    [Bin].

%% Ignore white space at end of line
join_entry([<<"-----END CERTIFICATE-----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([<<"-----END RSA PRIVATE KEY-----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([<<"-----END PUBLIC KEY-----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([<<"-----END RSA PUBLIC KEY-----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([<<"-----END DSA PRIVATE KEY-----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([<<"-----END DH PARAMETERS-----", _/binary>>| Lines], Entry) ->
    {lists:reverse(Entry), Lines};
join_entry([Line | Lines], Entry) ->
    join_entry(Lines, [Line | Entry]).

decode_key(Data, Password, "DES-CBC", Salt) ->
    Key = password_to_key(Password, Salt, 8),
    IV = Salt,
    crypto:des_cbc_decrypt(Key, IV, Data);
decode_key(Data,  Password, "DES-EDE3-CBC", Salt) ->
    Key = password_to_key(Password, Salt, 24),
    IV = Salt,
    <<Key1:8/binary, Key2:8/binary, Key3:8/binary>> = Key,
    crypto:des_ede3_cbc_decrypt(Key1, Key2, Key3, IV, Data).

encode_key(Data, Password, "DES-CBC", Salt) ->
    Key = password_to_key(Password, Salt, 8),
    IV = Salt,
    crypto:des_cbc_encrypt(Key, IV, Data);
encode_key(Data, Password, "DES-EDE3-CBC", Salt) ->
    Key = password_to_key(Password, Salt, 24),
    IV = Salt,
    <<Key1:8/binary, Key2:8/binary, Key3:8/binary>> = Key,
    crypto:des_ede3_cbc_encrypt(Key1, Key2, Key3, IV, Data).

password_to_key(Data, Salt, KeyLen) ->
    <<Key:KeyLen/binary, _/binary>> = 
	password_to_key(<<>>, Data, Salt, KeyLen, <<>>),
    Key.

password_to_key(_, _, _, Len, Acc) when Len =< 0 ->
    Acc;
password_to_key(Prev, Data, Salt, Len, Acc) ->
    M = crypto:md5([Prev, Data, Salt]),
    password_to_key(M, Data, Salt, Len - size(M), <<Acc/binary, M/binary>>).

unhex(S) ->
    unhex(S, []).

unhex("", Acc) ->
    list_to_binary(lists:reverse(Acc));
unhex([D1, D2 | Rest], Acc) ->
    unhex(Rest, [erlang:list_to_integer([D1, D2], 16) | Acc]).

hexify(L) -> [[hex_byte(B)] || B <- binary_to_list(L)].

hex_byte(B) when B < 16#10 -> ["0", erlang:integer_to_list(B, 16)];
hex_byte(B) -> erlang:integer_to_list(B, 16).

pem_start('Certificate') ->
    <<"-----BEGIN CERTIFICATE-----">>;
pem_start('RSAPrivateKey') ->
    <<"-----BEGIN RSA PRIVATE KEY-----">>;
pem_start('RSAPublicKey') ->
    <<"-----BEGIN RSA PUBLIC KEY-----">>;
pem_start('SubjectPublicKeyInfo') ->
    <<"-----BEGIN PUBLIC KEY-----">>;
pem_start('DSAPrivateKey') ->
    <<"-----BEGIN DSA PRIVATE KEY-----">>;
pem_start('DHParameter') ->
    <<"-----BEGIN DH PARAMETERS-----">>.
pem_end(<<"-----BEGIN CERTIFICATE-----">>) ->
    <<"-----END CERTIFICATE-----">>;
pem_end(<<"-----BEGIN RSA PRIVATE KEY-----">>) ->
    <<"-----END RSA PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN RSA PUBLIC KEY-----">>) ->
    <<"-----END RSA PUBLIC KEY-----">>;
pem_end(<<"-----BEGIN PUBLIC KEY-----">>) ->
    <<"-----END PUBLIC KEY-----">>;
pem_end(<<"-----BEGIN DSA PRIVATE KEY-----">>) ->
    <<"-----END DSA PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN DH PARAMETERS-----">>) ->
    <<"-----END DH PARAMETERS-----">>;
pem_end(_) ->
    undefined.

asn1_type(<<"-----BEGIN CERTIFICATE-----">>) ->
    'Certificate';
asn1_type(<<"-----BEGIN RSA PRIVATE KEY-----">>) ->
    'RSAPrivateKey';
asn1_type(<<"-----BEGIN RSA PUBLIC KEY-----">>) ->
    'RSAPublicKey';
asn1_type(<<"-----BEGIN PUBLIC KEY-----">>) ->
    'SubjectPublicKeyInfo';
asn1_type(<<"-----BEGIN DSA PRIVATE KEY-----">>) ->
    'DSAPrivateKey';
asn1_type(<<"-----BEGIN DH PARAMETERS-----">>) ->
    'DHParameter'.

pem_decrypt() ->
    <<"Proc-Type: 4,ENCRYPTED">>.

pem_decrypt_info(Cipher, Salt) ->
    io_lib:format("DEK-Info: ~s,~s", [Cipher, lists:flatten(hexify(Salt))]).

%%--------------------------------------------------------------------
%%% Deprecated
%%--------------------------------------------------------------------
decode_key({_Type, Bin, not_encrypted}, _) ->
    Bin;
decode_key({_Type, Bin, {Chipher,Salt}}, Password) ->
    decode_key(Bin, Password, Chipher, Salt).
