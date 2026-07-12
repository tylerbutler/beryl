import gleam/option.{type Option, None, Some}

/// Returns the reconnect delay in milliseconds for the given attempt number,
/// or None if retries are exhausted (> 5 attempts).
pub fn delay(attempt: Int) -> Option(Int) {
  case attempt {
    1 -> Some(1000)
    2 -> Some(2000)
    3 -> Some(5000)
    4 | 5 -> Some(10_000)
    _ -> None
  }
}
