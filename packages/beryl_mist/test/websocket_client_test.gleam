import gleeunit/should

@external(erlang, "beryl_mist_transport_test_ffi", "coalesced_upgrade_frames")
fn coalesced_upgrade_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "split_upgrade_frames")
fn split_upgrade_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "empty_text_control_frames")
fn empty_text_control_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "empty_binary_frames")
fn empty_binary_frames() -> Result(List(BitArray), Nil)

pub fn preserves_multiple_frames_coalesced_with_upgrade_test() -> Nil {
  coalesced_upgrade_frames()
  |> should.equal(Ok(["first", "second"]))
}

pub fn preserves_partial_frame_after_split_upgrade_headers_test() -> Nil {
  split_upgrade_frames()
  |> should.equal(Ok(["third", "fourth"]))
}

pub fn reads_empty_text_and_control_payloads_test() -> Nil {
  empty_text_control_frames()
  |> should.equal(Ok(["", "", "next"]))
}

pub fn reads_empty_binary_payload_and_following_frame_test() -> Nil {
  empty_binary_frames()
  |> should.equal(Ok([<<>>, <<"next":utf8>>]))
}
