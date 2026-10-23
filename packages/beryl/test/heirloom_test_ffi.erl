-module(heirloom_test_ffi).
-export([send_transfer/3, send_invalid_table_transfer/2]).

send_transfer(Table, PreviousOwner, Data) ->
    self() ! {'ETS-TRANSFER', Table, PreviousOwner, Data},
    nil.

send_invalid_table_transfer(PreviousOwner, Data) ->
    self() ! {'ETS-TRANSFER', make_ref(), PreviousOwner, Data},
    nil.
