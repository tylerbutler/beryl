//// Human-readable ID generation
////
//// Generates memorable IDs like "bold-otter-42" for use as socket identifiers.
////
//// Word lists are vendored from the anonymous_name_generator Elixir package
//// (https://hex.pm/packages/anonymous_name_generator) by Tyler Mecklem,
//// licensed under the MIT License.

import gleam/int
import gleam/list

/// Generate a human-readable ID (e.g., "bold-otter-42")
///
/// Combines a random adjective, noun, and 4-digit number for ~138K x 10000
/// = ~1.3 billion combinations.
pub fn generate() -> String {
  let adjective = pick(adjectives)
  let noun = pick(nouns)
  let number = random_int(10_000)
  adjective <> "-" <> noun <> "-" <> int.to_string(number)
}

@external(erlang, "rand", "uniform")
fn random_int(max: Int) -> Int

fn pick(words: List(String)) -> String {
  let count = list.length(words)
  let index = random_int(count) - 1
  case list.drop(words, index) {
    [word, ..] -> word
    [] -> "unknown"
  }
}

// 299 adjectives
const adjectives = [
  "abandoned", "acidic", "acrobatic", "adorable", "affectionate", "aged",
  "aggressive", "agile", "alert", "ambitious", "ancient", "angry", "anxious",
  "aromatic", "artistic", "ashamed", "attractive", "autumn", "aware", "awful",
  "bald", "beautiful", "beloved", "bewildered", "big", "billowing",
  "biodegradable", "bitter", "black", "blissful", "blue", "blushing", "bogus",
  "bold", "boring", "bossy", "brave", "breezy", "broken", "bruised", "bubbly",
  "bumpy", "busy", "buzzing", "calm", "careful", "cautious", "charming",
  "cheery", "chilly", "chubby", "clean", "clever", "clumsy", "cold",
  "colossal", "cool", "creamy", "crimson", "cuddly", "damaged", "damp", "dark",
  "dawn", "dazzling", "decaying", "decent", "delayed", "delicate", "delicious",
  "delightful", "delirious", "devoted", "diligent", "dirty", "disgusting",
  "divine", "drab", "dry", "eager", "easy", "ecstatic", "edible", "elastic",
  "elderly", "elegant", "embarrassed", "empty", "expensive", "faithful", "fake",
  "falling", "famous", "fancy", "fast", "fat", "feisty", "fierce", "firm",
  "fit", "flabby", "flaky", "flashy", "flawed", "floral", "fluffy", "fragrant",
  "fresh", "frosty", "gaseous", "gentle", "giant", "gifted", "gigantic",
  "glamorous", "glaring", "glossy", "gorgeous", "greasy", "great", "greedy",
  "green", "grumpy", "hairy", "handsome", "happy", "haunting", "helpful",
  "helpless", "hidden", "hideous", "holy", "hot", "huge", "icky", "icy",
  "immense", "important", "infinite", "interesting", "itchy", "jaded",
  "jealous", "jolly", "juicy", "jumpy", "kind", "lanky", "large", "late",
  "lazy", "lean", "legal", "lingering", "little", "lively", "long", "loose",
  "mad", "magnificent", "massive", "melted", "merry", "messy", "microscopic",
  "mighty", "miniature", "minty", "misty", "moist", "moldy", "morning",
  "muddy", "muscular", "mushy", "mysterious", "nameless", "nasty", "nervous",
  "nice", "nifty", "noxious", "numb", "nutritious", "nutty", "obedient",
  "obnoxious", "odd", "oily", "old", "optimistic", "patient", "pesky",
  "petite", "phony", "pitiful", "plain", "plump", "polished", "polite",
  "poor", "powerful", "prickly", "proud", "pungent", "purple", "pushy",
  "quaint", "quiet", "radiant", "rancid", "rapid", "reckless", "red",
  "reflecting", "regal", "remorseful", "repulsive", "restless", "rich",
  "rigid", "ripe", "rotten", "rough", "rowdy", "royal", "rude", "salty",
  "sarcastic", "savory", "scary", "scrawny", "scruffy", "secret", "shady",
  "shaggy", "sharp", "shiny", "short", "shrill", "shy", "silent", "silky",
  "silly", "sizzling", "skinny", "slimy", "slushy", "small", "snappy", "snowy",
  "solitary", "soupy", "sour", "sparkling", "spicy", "spring", "stale",
  "sticky", "still", "stocky", "strange", "strong", "summer", "sweaty",
  "sweet", "tall", "tame", "tangy", "tart", "tasty", "teeny", "tender",
  "terrible", "thankful", "throbbing", "tight", "tiny", "twilight", "ugly",
  "uptight", "vast", "victorious", "wandering", "warm", "weak", "weathered",
  "wet", "white", "wild", "winter", "wispy", "withered", "witty", "wonderful",
  "worried", "young", "yummy", "zealous",
]

// 464 nouns
const nouns = [
  "aardvark", "afternoon", "airplane", "albatross", "alcove", "alligator",
  "alpaca", "anesthesiologist", "ankle", "anklet", "ant", "anteater",
  "antelope", "apartment", "ape", "apology", "apparatus", "apple", "appliance",
  "apron", "armadillo", "armor", "arrow", "attic", "baboon", "bag",
  "balaclava", "balcony", "balloon", "banana", "bank", "barn", "basement",
  "bassoon", "bat", "bathrobe", "bathroom", "battery", "bean", "bear", "beast",
  "belt", "beret", "bike", "bikini", "billboard", "bird", "blazer", "blizzard",
  "boar", "bobcat", "bongo", "bonnet", "book", "box", "bracelet", "breeze",
  "brick", "bronco", "brook", "bubble", "buffalo", "bug", "bugle", "bungalow",
  "bush", "butterfly", "cabana", "cabbage", "cabin", "cable", "cactus", "cake",
  "calendar", "camel", "cap", "cape", "cardigan", "casino", "castle", "cat",
  "cathedral", "cellar", "chair", "chalet", "chandelier", "chapel", "cheetah",
  "cherry", "chest", "chimpanzee", "chipmunk", "cloak", "clock", "closet",
  "cloud", "cobweb", "cockroach", "concrete", "corridor", "costume", "cottage",
  "cow", "crocodile", "croissant", "crow", "crown", "cub", "darkness", "dawn",
  "deer", "desk", "dew", "dinosaur", "dirt", "disguise", "dog", "dogsled",
  "dolphin", "donkey", "doorknob", "dragon", "dream", "dress", "drizzle",
  "duck", "dungeon", "dust", "eagle", "egg", "eggplant", "elbow", "element",
  "elephant", "elevator", "elk", "emu", "eye", "fan", "feather", "fedora",
  "field", "finger", "fire", "firefly", "fireman", "fireplace", "fish",
  "flower", "fog", "foot", "forest", "fortress", "fountain", "fox", "frog",
  "frost", "furnace", "galaxy", "gallery", "garage", "garden", "gate",
  "gauntlet", "guava", "gazebo", "gazelle", "geese", "gem", "gerbil", "ghost",
  "giraffe", "glade", "glitter", "glockenspiel", "glove", "goat", "goldfish",
  "goose", "gorilla", "grape", "grass", "grasshopper", "greenhouse",
  "hacienda", "hallway", "hamster", "hat", "hawk", "haze", "heart", "hedge",
  "hedgehog", "hen", "hill", "hog", "honeybee", "horn", "hornet", "horse",
  "hostel", "hotel", "hut", "hyena", "igloo", "inn", "island", "jackal",
  "jacket", "jaguar", "jar", "jaw", "jellyfish", "jewel", "jewelry",
  "jumpsuit", "kangaroo", "keyboard", "kid", "kilt", "kimono", "kiosk",
  "kitchen", "kite", "kitten", "kitty", "koala", "ladybug", "lake", "lamb",
  "lawn", "lawyer", "leaf", "lemur", "leotard", "lighthouse", "lion", "lips",
  "locket", "loincloth", "luggage", "lung", "mammoth", "mango", "manor",
  "mansion", "mask", "meadow", "monastery", "monkey", "monocle", "moon",
  "morning", "motel", "moth", "mountain", "mouse", "mouth", "mule", "mutt",
  "night", "nightgown", "nose", "nursery", "ocelot", "onion", "opossum",
  "orangutan", "orchard", "osprey", "ostrich", "otter", "oven", "owl", "ox",
  "pagoda", "panda", "panther", "pantry", "pantsuit", "paper", "parrot",
  "patio", "pavilion", "peacoat", "peacock", "pencil", "pendant", "petticoat",
  "pickle", "pig", "pigeon", "pine", "platypus", "pomegranate", "poncho",
  "pond", "pony", "popcorn", "porch", "porcupine", "portfolio", "potato",
  "puma", "puppy", "purse", "pyramid", "quicksand", "quill", "raccoon", "rag",
  "rain", "ranch", "rat", "raven", "resonance", "restaurant", "rhinoceros",
  "river", "robe", "rooster", "saloon", "sandals", "sandwich", "scarecrow",
  "scarf", "school", "sea", "seagull", "seal", "shack", "shadow", "shape",
  "shark", "shed", "sheep", "shirt", "sidewalk", "silence", "silo", "skunk",
  "sky", "skyscraper", "slime", "sloth", "smell", "smile", "smoke", "snail",
  "snake", "sneeze", "snow", "snowflake", "snowstorm", "society", "sock",
  "soda", "sombrero", "sound", "spaghetti", "spandex", "sparrow", "spider",
  "spike", "sponge", "spoon", "sprout", "spruce", "squirrel", "stable",
  "stadium", "stag", "stage", "staircase", "stallion", "star", "stew",
  "stomach", "stove", "stranger", "studio", "suggestion", "suit", "suitcase",
  "sun", "sunset", "supermarket", "surf", "swamp", "swan", "sweater",
  "swimsuit", "swordfish", "table", "tavern", "taxicab", "telephone",
  "television", "tendency", "tepee", "textbook", "theater", "thistle",
  "throne", "thunder", "tiara", "tie", "tiger", "toad", "toaster", "toga",
  "tongue", "toothbrush", "toothpaste", "tortoise", "tower", "townhouse",
  "tree", "trousers", "tunic", "turkey", "turnip", "turtle", "tuxedo",
  "twister", "typhoon", "umbrella", "underpants", "underwear", "uniform",
  "utensil", "vacuum", "van", "veil", "vest", "villa", "vineyard", "violet",
  "violin", "visitor", "visor", "voice", "volcano", "vulture", "wallaby",
  "wallet", "wasp", "watch", "water", "waterfall", "wave", "weasel", "whale",
  "wildflower", "wind", "window", "witch", "wolf", "wombat", "wood", "worm",
  "wrist", "yard", "zebra",
]
