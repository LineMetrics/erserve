%%------------------------------------------------------------------------------
%% @doc This module handles the binary protocol communication with an Rserve
%%      server, sending and receiving messages, and parsing them to an internal
%%      format. Unimplemented data types are received simply as a binary blob.
%%
%% @author Daniel Eliasson <daniel@danieleliasson.com>
%% @copyright 2012 Daniel Eliasson; Apache 2.0 license -- see LICENSE file
%% @end-------------------------------------------------------------------------
-module(erserve_comms).


%%%_* Exports ------------------------------------------------------------------
-export([ receive_connection_ack/1
        , receive_reply/1
        , send_message/3
        ]).


%%%_* Includes -----------------------------------------------------------------
-include_lib("erserve.hrl").


%%%_* External API -------------------------------------------------------------

-spec receive_connection_ack(erserve:connection()) -> ok.
receive_connection_ack(Conn) ->
  {ok, Msg} = gen_tcp:recv(Conn, 32),
  <<"Rsrv", _Version:32, _Protocol:32, _Extra/binary>> = Msg,
  ok.

-spec receive_reply(erserve:connection()) ->
                       {ok, erserve:r_data()} |
                       {error, erserve:error_code(), binary()}.
receive_reply(Conn) ->
  {ok, AckCode} = gen_tcp:recv(Conn, 4),
  case AckCode of
    <<?resp_ok:32/integer-little>> -> receive_reply_1(Conn);
    _                              -> receive_reply_error(Conn, AckCode)
  end.

-spec send_message( erserve:connection()
                  , erserve:type()
                  , erserve:untagged_data()) -> ok | {error, term()}.
send_message(Conn, Type, Data) ->
  Message = message(Type, Data),
  gen_tcp:send(Conn, Message).


%%%_* Rserve reply receiving functions -----------------------------------------

receive_reply_1(Conn) ->
  {ok, Msg} = gen_tcp:recv(Conn, 12),
  << Len0:32/integer-little
   , _Offset:32/integer-little
   , Len1:32/integer-little
  >>  = Msg,
  Len = Len0 + (Len1 bsl 31),
  {ok, receive_data(Conn, Len)}.

receive_reply_error(Conn, AckCode) ->
  <<2, 0, 1, ErrCode>> = AckCode,
  Error                = error_from_code(ErrCode),
  {ok, Rest}           = gen_tcp:recv(Conn, 0),
  {error, Error, Rest}.


%%%_* Data receiving functions -------------------------------------------------

receive_data(Conn, Length) ->
  case lists:reverse(receive_data(Conn, Length, [])) of
    [Item] -> Item;
    List   -> List
  end.

receive_data(_Conn, 0, Acc) ->
  Acc;
receive_data( Conn, Length, Acc) ->
  {ok, Header} = gen_tcp:recv(Conn, 4),
  << Type:8/integer-little
   , ItemLength:24/integer-little
  >> = Header,
  {Item, _L} = receive_item(Conn, Type),
  NewAcc = [Item|Acc],
  RemainingLength = Length - ItemLength - 4,
  receive_data(Conn, RemainingLength, NewAcc).

receive_item(Conn, ?dt_sexp) ->
  {ok, Header} = gen_tcp:recv(Conn, 4),
  << SexpType:8/integer-little
   , SexpLength:24/integer-little
  >> = Header,
  Item = receive_sexp(Conn, SexpType, SexpLength),
  {Item, SexpLength + 4}.

receive_sexp( Conn, Type,             Length) when Type > ?xt_has_attr ->
  %% SEXP has attributes, so we need to read off the attribute SEXP
  %% before we get to this expression proper
  {AttrSexp, AttrSexpLength} = receive_item(Conn, ?dt_sexp),
  Sexp                       = receive_sexp(Conn,
                                            Type - ?xt_has_attr,
                                            Length - AttrSexpLength),
  {xt_has_attr, {AttrSexp, Sexp}};
receive_sexp( Conn, Type,             Length) when Type > ?xt_large    ->
  %% SEXP is large, which means the length is coded as a
  %% 56-bit integer, enlarging the header by 4 bytes
  {ok, RestLength} = gen_tcp:recv(Conn, 4),
  FullLength = Length + (RestLength bsl 23),
  receive_sexp(Conn, Type - ?xt_large, FullLength);
receive_sexp(_Conn, ?xt_null,             0)                           ->
  {xt_null, null};
receive_sexp( Conn, ?xt_str,          Length)                          ->
  {xt_array_str, StringArray} = receive_string_array(Conn, Length),
  {xt_str, hd(StringArray)};
receive_sexp( Conn, ?xt_vector,       Length)                          ->
  receive_vector(Conn, Length, []);
receive_sexp( Conn, ?xt_symname,      Length)                          ->
  receive_sexp(Conn, ?xt_str, Length);
receive_sexp( Conn, ?xt_list_notag,   Length)                          ->
  receive_sexp(Conn, ?xt_vector, Length);
receive_sexp( Conn, ?xt_list_tag,     Length)                          ->
  receive_tagged_list(Conn, Length, []);
receive_sexp( Conn, ?xt_lang_notag,   Length)                          ->
  receive_sexp(Conn, ?xt_list_notag, Length);
receive_sexp( Conn, ?xt_lang_tag,     Length)                          ->
  receive_sexp(Conn, ?xt_list_tag, Length);
receive_sexp( Conn, ?xt_vector_exp,   Length)                          ->
  receive_sexp(Conn, ?xt_vector, Length);
receive_sexp( Conn, ?xt_clos,         Length)                          ->
  receive_closure(Conn, Length);
receive_sexp( Conn, ?xt_array_int,    Length)                          ->
  receive_int_array(Conn, Length, []);
receive_sexp( Conn, ?xt_array_double, Length)                          ->
  receive_double_array(Conn, Length, []);
receive_sexp( Conn, ?xt_array_str,    Length)                          ->
  receive_string_array(Conn, Length);
receive_sexp( Conn, ?xt_array_bool,   Length)                          ->
  receive_bool_array(Conn, Length);
receive_sexp( Conn, UnimplType,       Length)                          ->
  receive_unimplemented_type(Conn, UnimplType, Length).


%%%_* Numeric data receiving functions -----------------------------------------

receive_int_array(_Conn, 0,      Acc) ->
  {xt_array_int, lists:reverse(Acc)};
receive_int_array( Conn, Length, Acc) ->
  Int             = receive_int(Conn),
  NewAcc          = [Int|Acc],
  RemainingLength = Length - 4,
  receive_int_array(Conn, RemainingLength, NewAcc).

receive_int(Conn) ->
  {ok, Data}                        = gen_tcp:recv(Conn, 4),
  <<Int0:32/integer-signed-little>> = Data,
  case Int0 of
    ?na_int -> null;
    Int     -> Int
  end.

receive_double_array(_Conn, 0,      Acc) ->
  {xt_array_double, lists:reverse(Acc)};
receive_double_array( Conn, Length, Acc) ->
  Double          = receive_double(Conn),
  NewAcc          = [Double|Acc],
  RemainingLength = Length - 8,
  receive_double_array(Conn, RemainingLength, NewAcc).

receive_double(Conn) ->
  {ok, Data0}         = gen_tcp:recv(Conn, 8),
  Data                = change_double_endianness(Data0),
  <<S:1, E:11, M:52>> = Data,
  case E of
    ?nan_double_exp -> receive_nan_double(S, M);
    _               -> receive_real_double(Data)
  end.

-spec receive_nan_double(0 | 1, Mantissa :: 0)         -> inf | '-inf';
                        (0 | 1, Mantissa :: 16#7a2)    -> null;
                        (0 | 1, Mantissa :: integer()) -> nan.
receive_nan_double(S, M) ->
  case M of
    ?nan_double_inf_mantissa -> receive_inf_double(S);
    ?nan_double_na_mantissa  -> null;
    _                        -> nan
  end.

-spec receive_inf_double(SignBit :: 0) -> inf;
                        (SignBit :: 1) -> '-inf'.
receive_inf_double(1) -> '-inf';
receive_inf_double(0) -> inf.

-spec receive_real_double(binary()) -> float().
receive_real_double(Data) ->
  <<Double:64/float>> = Data,
  Double.

change_double_endianness(<<B8, B7, B6, B5, B4, B3, B2, B1>>) ->
  <<B1, B2, B3, B4, B5, B6, B7, B8>>.


%%%_* String receiving functions -----------------------------------------------

receive_string_array(_Conn, 0)     ->
  {xt_array_str, []};
receive_string_array(Conn, Length) ->
  {ok, Data} = gen_tcp:recv(Conn, Length),
  Strings0 = trim_padding_and_split_array_str(Data),
  Strings  = lists:map(fun trim_padding_and_parse_string/1, Strings0),
  {xt_array_str, Strings}.

%%------------------------------------------------------------------------------
%% @doc Strip off '\01'-padding, split on null terminators.
%% @private
%% @end-------------------------------------------------------------------------
trim_padding_and_split_array_str(Bin) when is_binary(Bin) ->
  String = string:strip(binary_to_list(Bin), right, 1),
  string:tokens(String, [0]).

%%------------------------------------------------------------------------------
%% @doc Strip off '\01'-padding, convert to binary, or null if <<255>>.
%% @private
%% @end-------------------------------------------------------------------------
trim_padding_and_parse_string(Str) when is_list(Str) ->
  case list_to_binary(string:strip(Str, left, 1)) of
    <<?na_string>> -> null;
    Bin            -> Bin
  end.


%%%_* Boolean receiving functions ----------------------------------------------

receive_bool_array(Conn, Length) ->
  {ok, Data0} = gen_tcp:recv(Conn, Length),
  << N:32/integer-little
   , Data/binary
  >>     = Data0,
  NBoolBits = N * ?size_bool * 8,
  << Bools:NBoolBits/bitstring
   , _Padding/binary
  >>    = Data,
  BoolArray = lists:map(fun(?na_boolean)     ->
                            null;
                           (?na_boolean_alt) ->
                            null;
                           (1)               ->
                            true;
                           (0)               ->
                            false
                        end, binary_to_list(Bools)),
  {xt_array_bool, BoolArray}.


%%%_* Vector and list receiving functions --------------------------------------

receive_tagged_list(_Conn, 0,      Acc) ->
  {xt_list_tag, lists:reverse(Acc)};
receive_tagged_list( Conn, Length, Acc) ->
  {Value, ValueLength} = receive_item(Conn, ?dt_sexp),
  {Key,   KeyLength}   = receive_item(Conn, ?dt_sexp),
  Item                 = {Key, Value},
  NewAcc               = [Item|Acc],
  RemainingLength      = Length - KeyLength - ValueLength,
  receive_tagged_list(Conn, RemainingLength, NewAcc).

receive_vector(_Conn, 0,      Acc) ->
  {xt_vector, lists:reverse(Acc)};
receive_vector( Conn, Length, Acc) ->
  {Item, UsedLength} = receive_item(Conn, ?dt_sexp),
  NewAcc = [Item|Acc],
  RemainingLength = Length - UsedLength,
  receive_vector(Conn, RemainingLength, NewAcc).


%%%_* Other data receiving functions -------------------------------------------

receive_closure(Conn, Length) ->
  {ok, Closure} = gen_tcp:recv(Conn, Length),
  {closure, Closure}.

receive_unimplemented_type(Conn, Type, Length) ->
  {{unimplemented_type, Type}, gen_tcp:recv(Conn, Length)}.


%%%_* Data sending functions ---------------------------------------------------

message(eval,      String) ->
  Body   = dt(string, String),
  Length = iolist_size(Body),
  [ header(?cmd_eval, Length)
  , Body
  ];
message(eval_void, String) ->
  Body   = dt(string, String),
  Length = iolist_size(Body),
  [ header(?cmd_void_eval, Length)
  , Body
  ];
message({set_variable, Type}, {Name0, Value0}) ->
  Name   = dt(string, Name0),
  Value  = dt(sexp,   {Type, Value0}),
  Body   = [Name, Value],
  Length = iolist_size(Body),
  [ header(?cmd_set_sexp, Length)
  , Body
  ].

header(Command, Length) ->
  << Command:32/integer-little
   , Length:32/integer-little
   , 0:32/integer-little        % offset
   , 0:32/integer-little        % currently only support 32-bit lengths
  >>.

dt(string, String0) ->
  String = transfer_string(String0),
  Length = iolist_size(String),
  [ << ?dt_string:8/integer-little
     , Length:24/integer-little >>
  , String
  ];
dt(sexp,   {Type, Sexp0}) ->
  Sexp   = transfer_sexp({Type, Sexp0}),
  Length = iolist_size(Sexp),
  [ << ?dt_sexp:8/integer-little
     , Length:24/integer-little >>
  , Sexp
  ].

xt(xt_array_bool, Booleans)     ->
  Payload = transfer_boolean_array(Booleans),
  [ xt_header(?xt_array_bool, Payload)
  , Payload
  ];
xt(xt_array_double, Doubles)    ->
  Payload = lists:map(fun transfer_double/1, Doubles),
  [ xt_header(?xt_array_double, Payload)
  , Payload
  ];
xt(xt_array_int,    Ints)       ->
  {Type, Payload} = transfer_ints(Ints),
  [ xt_header(Type, Payload)
  , Payload
  ];
xt(xt_array_str,    Strings)    ->
  Payload = transfer_string_array(Strings),
  [ xt_header(?xt_array_str, Payload)
  , Payload
  ];
xt(xt_list_tag,     TaggedList) ->
  Payload = lists:map(fun transfer_tagged/1, TaggedList),
  [ xt_header(?xt_list_tag, Payload)
  , Payload
  ];
xt(xt_str,          String)     ->
  Payload = transfer_string(String),
  [ xt_header(?xt_symname, Payload)
  , Payload
  ];
xt(xt_symname,      Symbol)     ->
  Payload = transfer_string(Symbol),
  [ xt_header(?xt_symname, Payload)
  , Payload
  ];
xt(xt_vector,       Elements)   ->
  Payload = lists:map(fun transfer_sexp/1, Elements),
  [ xt_header(?xt_vector, Payload)
  , Payload
  ];
xt(dataframe,       DataFrame)  ->
  transfer_df(DataFrame).

xt_header(Type, Payload) ->
  Length = iolist_size(Payload),
  << Type:8/integer-little
   , Length:24/integer-little
  >>.


%% Strings are transferred with a '\00' terminator and string arrays
%% are padded out with '\01' to become of a byte length that's divisible
%% by 4.
transfer_string_array(Strings) ->
  Payload = lists:map(fun transfer_string/1, Strings),
  pad_array(Payload).

transfer_string(String0) ->
  [String0, <<0>>].

transfer_boolean_array(Booleans) ->
  N       = length(Booleans),
  Data    = lists:map(fun(null)  ->
                          <<?na_boolean:(?size_bool * 8)>>;
                         (true)  ->
                          <<1:(?size_bool * 8)>>;
                         (false) ->
                          <<0:(?size_bool * 8)>>
                      end, Booleans),
  Payload = [<<N:32/integer-little>>, Data],
  pad_array(Payload).

pad_array(Payload) ->
  Length = iolist_size(Payload),
  case (Length rem 4) of
    0 -> Payload;
    N -> [Payload, binary:copy(<<1>>, 4 - N)]
  end.

%% Ints are special, since Erlang can handle arbitrary sized integers,
%% but R uses 32-bit ints. Therefore, we need to see if we can send the
%% integers as ints. If not, we try doubles. If that also fails, we
%% resort to string representation.
-spec transfer_ints([null | integer()]) ->
                       { ?xt_array_int,    [ null | integer() ] }
                     | { ?xt_array_double, [ null | float() ] }
                     | { ?xt_array_str,    [ null | string() ] }.
transfer_ints(Ints) ->
  Type    = r_type_for_int_array(Ints),
  Payload = case Type of
              ?xt_array_int    ->
                lists:map(fun transfer_int/1, Ints);
              ?xt_array_double ->
                IntsAsDoubles = lists:map(fun int_to_double/1, Ints),
                lists:map(fun transfer_double/1, IntsAsDoubles);
              ?xt_array_str    ->
                IntsAsStrings = lists:map(fun int_to_string/1, Ints),
                transfer_string_array(IntsAsStrings)
            end,
  {Type, Payload}.

-spec r_type_for_int_array([null | integer()]) -> ?xt_array_int
                                                | ?xt_array_double
                                                | ?xt_array_str.
r_type_for_int_array(Ints) ->
  lists:foldl(fun(Int, Type) ->
                  case {r_type_for_int(Int), Type} of
                    {?xt_array_int,    ?xt_array_int}    -> ?xt_array_int;
                    {?xt_array_int,    ?xt_array_double} -> ?xt_array_double;
                    {?xt_array_int,    ?xt_array_str}    -> ?xt_array_str;
                    {?xt_array_double, ?xt_array_int}    -> ?xt_array_double;
                    {?xt_array_double, ?xt_array_double} -> ?xt_array_double;
                    {?xt_array_double, ?xt_array_str}    -> ?xt_array_str;
                    {?xt_array_str,    _AnyType}         -> ?xt_array_str
                  end
              end, ?xt_array_int, Ints).

-spec r_type_for_int(null | integer()) -> ?xt_array_int
                                        | ?xt_array_double
                                        | ?xt_array_str.
r_type_for_int(null)                     -> ?xt_array_int;
r_type_for_int(Int) when is_integer(Int) ->
  if
    Int >= ?min_int andalso Int =< ?max_int       -> ?xt_array_int;
    Int >= ?min_double_int andalso Int < ?min_int -> ?xt_array_double;
    Int >= ?max_int andalso Int < ?max_double_int -> ?xt_array_double;
    true                                          -> ?xt_array_str
  end.

-spec int_to_double(null)      -> null;
                   (integer()) -> float().
int_to_double(null)                     -> null;
int_to_double(Int) when is_integer(Int) -> float(Int).

-spec int_to_string(null | integer()) -> string().
int_to_string(null)                     -> "NA";
int_to_string(Int) when is_integer(Int) -> integer_to_list(Int).


transfer_int(null) ->
  <<?na_int:(?size_int * 8)/integer-signed-little>>;
transfer_int(Int)  ->
  <<Int:(?size_int * 8)/integer-signed-little>>.

transfer_double(null)   ->
  ?nan_double_na_binary;
transfer_double(Double) ->
  <<Double:(?size_double * 8)/float-little>>.

transfer_tagged({Tag, Value}) ->
  [ transfer_sexp(Value)
  , transfer_sexp(Tag)
  ].

transfer_df(DataFrame) ->
  Names    = df_names(DataFrame),
  RowNames = df_row_names(DataFrame),
  Values   = df_values(DataFrame),
  AttrSexp = {xt_list_tag, [ { {xt_symname,   "names"}
                             , {xt_array_str, Names}
                             }
                           , { {xt_symname,   "row.names"}
                             , {xt_array_int, RowNames}
                             }
                           , { {xt_symname,   "class"}
                             , {xt_array_str, ["data.frame"]}
                             }
                           ]},
  transfer_sexp_with_attr(AttrSexp, {xt_vector, Values}).

transfer_sexp({Type, Data}) ->
  xt(Type, Data).

transfer_sexp_with_attr(AttrSexp, Sexp) ->
  AttrBin           = transfer_sexp(AttrSexp),
  [Header, Payload] = transfer_sexp(Sexp),
  FullPayload       = [AttrBin, Payload],
  << Type:8/integer-little
   , _Length:24/integer-little
  >> = Header,
  [ xt_header(Type + ?xt_has_attr, FullPayload)
  , FullPayload
  ].


%%%_* Helpers for sending lists and data frames --------------------------------

df_names(DataFrame) ->
  lists:map(fun({Name, _Type, _Values}) ->
                case Name of
                  NAtom when is_atom(NAtom)  -> atom_to_list(NAtom);
                  NBin  when is_binary(NBin) -> NBin;
                  NStr  when is_list(NStr)   -> NStr
                end
            end, DataFrame).

df_values(DataFrame) ->
  lists:map(fun({_Name, Type, Values}) ->
                {Type, Values}
            end, DataFrame).

df_row_names(DataFrame) ->
  {_Name, _Type, Values} = hd(DataFrame),
  N = length(Values),
  lists:seq(1, N).


%%%_* Error handling -----------------------------------------------------------

error_from_code(?err_auth_failed)     ->
  auth_failed;
error_from_code(?err_conn_broken)     ->
  connection_broken;
error_from_code(?err_inv_cmd)         ->
  invalid_command;
error_from_code(?err_inv_par)         ->
  invalid_parameters;
error_from_code(?err_r_error)         ->
  r_error_occurred;
error_from_code(?err_io_error)        ->
  io_error;
error_from_code(?err_not_open)        ->
  file_not_open;
error_from_code(?err_access_denied)   ->
  access_denied;
error_from_code(?err_unsupported_cmd) ->
  unsupported_command;
error_from_code(?err_unknown_cmd)     ->
  unknown_command;
error_from_code(?err_data_overflow)   ->
  data_overflow;
error_from_code(?err_object_too_big)  ->
  object_too_big;
error_from_code(?err_out_of_mem)      ->
  out_of_memory;
error_from_code(?err_ctrl_closed)     ->
  control_pipe_closed;
error_from_code(?err_session_busy)    ->
  session_busy;
error_from_code(?err_detach_failed)   ->
  unable_to_detach_session;
error_from_code(Other)                ->
  {unknown_error, Other}.
