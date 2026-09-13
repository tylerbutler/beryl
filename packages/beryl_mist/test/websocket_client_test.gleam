import gleeunit/should

@external(erlang, "beryl_mist_transport_test_ffi", "coalesced_upgrade_frames")
fn coalesced_upgrade_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_mist_transport_test_ffi", "split_upgrade_frames")
fn split_upgrade_frames() -> Result(List(String), Nil)

pub fn preserves_multiple_frames_coalesced_with_upgrade_test() -> Nil {
  coalesced_upgrade_frames()
  |> should.equal(Ok(["first", "second"]))
}

pub fn preserves_partial_frame_after_split_upgrade_headers_test() -> Nil {
  split_upgrade_frames()
  |> should.equal(Ok(["third", "fourth"]))
}
