import gleam/bit_array
import gleam/crypto
import gleam/http/request.{type Request}
import gleam/list
import gleam/result
import gleam/string

const cookie_name = "beryl_session"

pub type User {
  User(id: String, name: String, avatar_url: String)
}

pub fn new_secret() -> BitArray {
  crypto.strong_random_bytes(32)
}

pub fn find_user(id: String) -> Result(User, Nil) {
  users()
  |> list.find(fn(user) { user.id == id })
}

pub fn session_cookie(user: User, secret: BitArray) -> String {
  let token =
    crypto.sign_message(bit_array.from_string(user.id), secret, crypto.Sha256)

  cookie_name <> "=" <> token <> "; Path=/; HttpOnly; SameSite=Strict"
}

pub fn authenticate_request(
  http_request: Request(body),
  secret: BitArray,
) -> Result(User, Nil) {
  use cookie_header <- result.try(
    request.get_header(http_request, "cookie")
    |> result.replace_error(Nil),
  )
  use token <- result.try(find_cookie(cookie_header, cookie_name))
  use user_bits <- result.try(crypto.verify_signed_message(token, secret))
  use user_id <- result.try(bit_array.to_string(user_bits))
  find_user(user_id)
}

pub fn metadata(user: User) -> List(#(String, String)) {
  [
    #("user_id", user.id),
    #("name", user.name),
    #("avatar_url", user.avatar_url),
  ]
}

pub fn from_metadata(values: List(#(String, String))) -> Result(User, Nil) {
  use id <- result.try(list.key_find(values, "user_id"))
  use name <- result.try(list.key_find(values, "name"))
  use avatar_url <- result.try(list.key_find(values, "avatar_url"))
  Ok(User(id:, name:, avatar_url:))
}

fn users() -> List(User) {
  [
    User(id: "ada", name: "Ada Lovelace", avatar_url: "/static/ada.svg"),
    User(id: "grace", name: "Grace Hopper", avatar_url: "/static/grace.svg"),
  ]
}

fn find_cookie(header: String, name: String) -> Result(String, Nil) {
  header
  |> string.split(";")
  |> list.find_map(fn(part) {
    case string.split_once(string.trim(part), "=") {
      Ok(#(cookie, value)) if cookie == name -> Ok(value)
      Error(Nil) | Ok(_) -> Error(Nil)
    }
  })
}
