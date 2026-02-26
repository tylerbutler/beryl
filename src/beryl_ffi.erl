-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0]).

%% Identity function for type erasure
identity(X) -> X.

%% Return Erlang monotonic time in milliseconds
monotonic_time_ms() -> erlang:monotonic_time(millisecond).
