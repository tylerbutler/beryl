import beryl_site/component/presence_lab
import lustre

pub fn main() {
  let assert Ok(Nil) = lustre.register(presence_lab.app(), presence_lab.tag)
}
