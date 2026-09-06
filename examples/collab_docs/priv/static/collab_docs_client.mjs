// build/dev/javascript/prelude.mjs
var CustomType = class {
  withFields(fields) {
    let properties = Object.keys(this).map(
      (label) => label in fields ? fields[label] : this[label]
    );
    return new this.constructor(...properties);
  }
};
var List = class {
  static fromArray(array3, tail) {
    return toList(array3, tail);
  }
  [Symbol.iterator]() {
    return new ListIterator(this);
  }
  toArray() {
    return [...this];
  }
  atLeastLength(desired) {
    let current = this;
    while (desired-- > 0 && current) current = current.tail;
    return current !== void 0;
  }
  hasLength(desired) {
    let current = this;
    while (desired-- > 0 && current) current = current.tail;
    return desired === -1 && current instanceof Empty;
  }
  countLength() {
    let current = this;
    let length2 = 0;
    while (current) {
      current = current.tail;
      length2++;
    }
    return length2 - 1;
  }
};
function prepend(element, tail) {
  return new NonEmpty(element, tail);
}
function toList(elements, tail) {
  let t = tail || List$Empty$const;
  for (let i = elements.length - 1; i >= 0; --i) {
    t = new NonEmpty(elements[i], t);
  }
  return t;
}
var ListIterator = class {
  #current;
  constructor(current) {
    this.#current = current;
  }
  next() {
    if (this.#current instanceof Empty) {
      return { done: true };
    } else {
      let { head, tail } = this.#current;
      this.#current = tail;
      return { value: head, done: false };
    }
  }
};
var Empty = class extends List {
};
var List$Empty$const = new Empty();
var List$Empty = () => List$Empty$const;
var List$isEmpty = (value4) => value4 instanceof Empty;
var NonEmpty = class extends List {
  constructor(head, tail) {
    super();
    this.head = head;
    this.tail = tail;
  }
};
var List$NonEmpty = (head, tail) => new NonEmpty(head, tail);
var List$isNonEmpty = (value4) => value4 instanceof NonEmpty;
var List$NonEmpty$first = (value4) => value4.head;
var List$NonEmpty$rest = (value4) => value4.tail;
var BitArray = class {
  /**
   * The size in bits of this bit array's data.
   *
   * @type {number}
   */
  bitSize;
  /**
   * The size in bytes of this bit array's data. If this bit array doesn't store
   * a whole number of bytes then this value is rounded up.
   *
   * @type {number}
   */
  byteSize;
  /**
   * The number of unused high bits in the first byte of this bit array's
   * buffer prior to the start of its data. The value of any unused high bits is
   * undefined.
   *
   * The bit offset will be in the range 0-7.
   *
   * @type {number}
   */
  bitOffset;
  /**
   * The raw bytes that hold this bit array's data.
   *
   * If `bitOffset` is not zero then there are unused high bits in the first
   * byte of this buffer.
   *
   * If `bitOffset + bitSize` is not a multiple of 8 then there are unused low
   * bits in the last byte of this buffer.
   *
   * @type {Uint8Array}
   */
  rawBuffer;
  /**
   * Constructs a new bit array from a `Uint8Array`, an optional size in
   * bits, and an optional bit offset.
   *
   * If no bit size is specified it is taken as `buffer.length * 8`, i.e. all
   * bytes in the buffer make up the new bit array's data.
   *
   * If no bit offset is specified it defaults to zero, i.e. there are no unused
   * high bits in the first byte of the buffer.
   *
   * @param {Uint8Array} buffer
   * @param {number} [bitSize]
   * @param {number} [bitOffset]
   */
  constructor(buffer, bitSize, bitOffset) {
    if (!(buffer instanceof Uint8Array)) {
      throw globalThis.Error(
        "BitArray can only be constructed from a Uint8Array"
      );
    }
    this.bitSize = bitSize ?? buffer.length * 8;
    this.byteSize = Math.trunc((this.bitSize + 7) / 8);
    this.bitOffset = bitOffset ?? 0;
    if (this.bitSize < 0) {
      throw globalThis.Error(`BitArray bit size is invalid: ${this.bitSize}`);
    }
    if (this.bitOffset < 0 || this.bitOffset > 7) {
      throw globalThis.Error(
        `BitArray bit offset is invalid: ${this.bitOffset}`
      );
    }
    if (buffer.length !== Math.trunc((this.bitOffset + this.bitSize + 7) / 8)) {
      throw globalThis.Error("BitArray buffer length is invalid");
    }
    this.rawBuffer = buffer;
  }
  /**
   * Returns a specific byte in this bit array. If the byte index is out of
   * range then `undefined` is returned.
   *
   * When returning the final byte of a bit array with a bit size that's not a
   * multiple of 8, the content of the unused low bits are undefined.
   *
   * @param {number} index
   * @returns {number | undefined}
   */
  byteAt(index4) {
    if (index4 < 0 || index4 >= this.byteSize) {
      return void 0;
    }
    return bitArrayByteAt(this.rawBuffer, this.bitOffset, index4);
  }
  equals(other) {
    if (this.bitSize !== other.bitSize) {
      return false;
    }
    const wholeByteCount = Math.trunc(this.bitSize / 8);
    if (this.bitOffset === 0 && other.bitOffset === 0) {
      for (let i = 0; i < wholeByteCount; i++) {
        if (this.rawBuffer[i] !== other.rawBuffer[i]) {
          return false;
        }
      }
      const trailingBitsCount = this.bitSize % 8;
      if (trailingBitsCount) {
        const unusedLowBitCount = 8 - trailingBitsCount;
        if (this.rawBuffer[wholeByteCount] >> unusedLowBitCount !== other.rawBuffer[wholeByteCount] >> unusedLowBitCount) {
          return false;
        }
      }
    } else {
      for (let i = 0; i < wholeByteCount; i++) {
        const a = bitArrayByteAt(this.rawBuffer, this.bitOffset, i);
        const b = bitArrayByteAt(other.rawBuffer, other.bitOffset, i);
        if (a !== b) {
          return false;
        }
      }
      const trailingBitsCount = this.bitSize % 8;
      if (trailingBitsCount) {
        const a = bitArrayByteAt(
          this.rawBuffer,
          this.bitOffset,
          wholeByteCount
        );
        const b = bitArrayByteAt(
          other.rawBuffer,
          other.bitOffset,
          wholeByteCount
        );
        const unusedLowBitCount = 8 - trailingBitsCount;
        if (a >> unusedLowBitCount !== b >> unusedLowBitCount) {
          return false;
        }
      }
    }
    return true;
  }
  /**
   * Returns this bit array's internal buffer.
   *
   * @deprecated
   *
   * @returns {Uint8Array}
   */
  get buffer() {
    if (this.bitOffset !== 0 || this.bitSize % 8 !== 0) {
      throw new globalThis.Error(
        "BitArray.buffer does not support unaligned bit arrays"
      );
    }
    return this.rawBuffer;
  }
  /**
   * Returns the length in bytes of this bit array's internal buffer.
   *
   * @deprecated
   *
   * @returns {number}
   */
  get length() {
    if (this.bitOffset !== 0 || this.bitSize % 8 !== 0) {
      throw new globalThis.Error(
        "BitArray.length does not support unaligned bit arrays"
      );
    }
    return this.rawBuffer.length;
  }
};
function bitArrayByteAt(buffer, bitOffset, index4) {
  if (bitOffset === 0) {
    return buffer[index4] ?? 0;
  } else {
    const a = buffer[index4] << bitOffset & 255;
    const b = buffer[index4 + 1] >> 8 - bitOffset;
    return a | b;
  }
}
var Result = class _Result extends CustomType {
  static isResult(data) {
    return data instanceof _Result;
  }
};
var Ok = class extends Result {
  constructor(value4) {
    super();
    this[0] = value4;
  }
  isOk() {
    return true;
  }
};
var Result$Ok = (value4) => new Ok(value4);
var Result$isOk = (value4) => value4 instanceof Ok;
var Error = class extends Result {
  constructor(detail) {
    super();
    this[0] = detail;
  }
  isOk() {
    return false;
  }
};
var Result$Error = (detail) => new Error(detail);
var Result$isError = (value4) => value4 instanceof Error;
function isEqual(x, y) {
  let values2 = [x, y];
  while (values2.length) {
    let a = values2.pop();
    let b = values2.pop();
    if (a === b) continue;
    if (!isObject(a) || !isObject(b)) return false;
    let unequal = !structurallyCompatibleObjects(a, b) || unequalDates(a, b) || unequalBuffers(a, b) || unequalArrays(a, b) || unequalMaps(a, b) || unequalSets(a, b) || unequalRegExps(a, b);
    if (unequal) return false;
    const proto = Object.getPrototypeOf(a);
    if (proto !== null && typeof proto.equals === "function") {
      try {
        if (a.equals(b)) continue;
        else return false;
      } catch {
      }
    }
    let [keys3, get4] = getters(a);
    const ka = keys3(a);
    const kb = keys3(b);
    if (ka.length !== kb.length) return false;
    for (let k of ka) {
      values2.push(get4(a, k), get4(b, k));
    }
  }
  return true;
}
function getters(object3) {
  if (object3 instanceof Map) {
    return [(x) => x.keys(), (x, y) => x.get(y)];
  } else {
    let extra = object3 instanceof globalThis.Error ? ["message"] : [];
    return [(x) => [...extra, ...Object.keys(x)], (x, y) => x[y]];
  }
}
function unequalDates(a, b) {
  return a instanceof Date && (a > b || a < b);
}
function unequalBuffers(a, b) {
  return !(a instanceof BitArray) && a.buffer instanceof ArrayBuffer && a.BYTES_PER_ELEMENT && !(a.byteLength === b.byteLength && a.every((n, i) => n === b[i]));
}
function unequalArrays(a, b) {
  return Array.isArray(a) && a.length !== b.length;
}
function unequalMaps(a, b) {
  return a instanceof Map && a.size !== b.size;
}
function unequalSets(a, b) {
  return a instanceof Set && (a.size != b.size || [...a].some((e) => !b.has(e)));
}
function unequalRegExps(a, b) {
  return a instanceof RegExp && (a.source !== b.source || a.flags !== b.flags);
}
function isObject(a) {
  return typeof a === "object" && a !== null;
}
function structurallyCompatibleObjects(a, b) {
  if (typeof a !== "object" && typeof b !== "object" && (!a || !b))
    return false;
  let nonstructural = [Promise, WeakSet, WeakMap, Function];
  if (nonstructural.some((c) => a instanceof c)) return false;
  return a.constructor === b.constructor;
}

// build/dev/javascript/gleam_stdlib/gleam/order.mjs
var Lt = class extends CustomType {
};
var Order$Lt$const = new Lt();
var Eq = class extends CustomType {
};
var Order$Eq$const = new Eq();
var Gt = class extends CustomType {
};
var Order$Gt$const = new Gt();

// build/dev/javascript/gleam_stdlib/gleam/option.mjs
var Some = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var None = class extends CustomType {
};
var Option$None$const = new None();

// build/dev/javascript/gleam_stdlib/dict.mjs
var referenceMap = /* @__PURE__ */ new WeakMap();
var tempDataView = /* @__PURE__ */ new DataView(
  /* @__PURE__ */ new ArrayBuffer(8)
);
var referenceUID = 0;
function hashByReference(o) {
  const known = referenceMap.get(o);
  if (known !== void 0) {
    return known;
  }
  const hash = referenceUID++;
  if (referenceUID === 2147483647) {
    referenceUID = 0;
  }
  referenceMap.set(o, hash);
  return hash;
}
function hashMerge(a, b) {
  return a ^ b + 2654435769 + (a << 6) + (a >> 2) | 0;
}
function hashString(s) {
  let hash = 0;
  const len = s.length;
  for (let i = 0; i < len; i++) {
    hash = Math.imul(31, hash) + s.charCodeAt(i) | 0;
  }
  return hash;
}
function hashNumber(n) {
  tempDataView.setFloat64(0, n);
  const i = tempDataView.getInt32(0);
  const j = tempDataView.getInt32(4);
  return Math.imul(73244475, i >> 16 ^ i) ^ j;
}
function hashBigInt(n) {
  return hashString(n.toString());
}
function hashObject(o) {
  const proto = Object.getPrototypeOf(o);
  if (proto !== null && typeof proto.hashCode === "function") {
    try {
      const code = o.hashCode(o);
      if (typeof code === "number") {
        return code;
      }
    } catch {
    }
  }
  if (o instanceof Promise || o instanceof WeakSet || o instanceof WeakMap) {
    return hashByReference(o);
  }
  if (o instanceof Date) {
    return hashNumber(o.getTime());
  }
  let h = 0;
  if (o instanceof ArrayBuffer) {
    o = new Uint8Array(o);
  }
  if (Array.isArray(o) || o instanceof Uint8Array) {
    for (let i = 0; i < o.length; i++) {
      h = Math.imul(31, h) + getHash(o[i]) | 0;
    }
  } else if (o instanceof Set) {
    o.forEach((v) => {
      h = h + getHash(v) | 0;
    });
  } else if (o instanceof Map) {
    o.forEach((v, k) => {
      h = h + hashMerge(getHash(v), getHash(k)) | 0;
    });
  } else {
    const keys3 = Object.keys(o);
    for (let i = 0; i < keys3.length; i++) {
      const k = keys3[i];
      const v = o[k];
      h = h + hashMerge(getHash(v), hashString(k)) | 0;
    }
  }
  return h;
}
function getHash(u) {
  if (u === null) return 1108378658;
  if (u === void 0) return 1108378659;
  if (u === true) return 1108378657;
  if (u === false) return 1108378656;
  switch (typeof u) {
    case "number":
      return hashNumber(u);
    case "string":
      return hashString(u);
    case "bigint":
      return hashBigInt(u);
    case "object":
      return hashObject(u);
    case "symbol":
      return hashByReference(u);
    case "function":
      return hashByReference(u);
    default:
      return 0;
  }
}
var Dict = class {
  constructor(size2, root) {
    this.size = size2;
    this.root = root;
  }
};
var bits = 5;
var mask = (1 << bits) - 1;
var noElementMarker = /* @__PURE__ */ Symbol();
var Node = class _Node {
  constructor(generation, datamap, nodemap, data) {
    this.datamap = datamap;
    this.nodemap = nodemap;
    this.data = data;
    this.generation = generation;
  }
  equals(other) {
    if (this === other) return true;
    if (!(other instanceof _Node)) return false;
    if (this.datamap !== other.datamap || this.nodemap !== other.nodemap) {
      return false;
    }
    const leftData = this.data;
    const rightData = other.data;
    if (leftData.length !== rightData.length) return false;
    if (this.datamap === 0 && this.nodemap === 0) {
      return this.#equalsOverflowEntries(rightData);
    }
    const edgesStart = leftData.length - popcount(this.nodemap);
    for (let i = 0; i < edgesStart; i += 2) {
      if (!isEqual(leftData[i], rightData[i]) || !isEqual(leftData[i + 1], rightData[i + 1])) {
        return false;
      }
    }
    for (let i = edgesStart; i < leftData.length; ++i) {
      if (!leftData[i].equals(rightData[i])) return false;
    }
    return true;
  }
  #equalsOverflowEntries(otherData) {
    const data = this.data;
    entries: for (let i = 0; i < data.length; i += 2) {
      for (let j = 0; j < otherData.length; j += 2) {
        if (isEqual(data[i], otherData[j])) {
          if (!isEqual(data[i + 1], otherData[j + 1])) return false;
          continue entries;
        }
      }
      return false;
    }
    return true;
  }
  hashCode() {
    const data = this.data;
    const edgesStart = data.length - popcount(this.nodemap);
    let hash = 0;
    for (let i = 0; i < edgesStart; i += 2) {
      hash = hash + hashMerge(getHash(data[i + 1]), getHash(data[i])) | 0;
    }
    for (let i = edgesStart; i < data.length; ++i) {
      hash = hash + data[i].hashCode() | 0;
    }
    return hash;
  }
};
var emptyNode = /* @__PURE__ */ newNode(0);
var emptyDict = /* @__PURE__ */ new Dict(0, emptyNode);
var errorNil = /* @__PURE__ */ Result$Error(void 0);
function newNode(generation) {
  return new Node(generation, 0, 0, []);
}
function copyNode(node, generation) {
  if (node.generation === generation) {
    return node;
  }
  const newData = node.data.slice(0);
  return new Node(generation, node.datamap, node.nodemap, newData);
}
function copyAndSet(node, generation, idx, val) {
  if (node.data[idx] === val) {
    return node;
  }
  node = copyNode(node, generation);
  node.data[idx] = val;
  return node;
}
function copyAndInsertPair(node, generation, bit, idx, key, val) {
  const data = node.data;
  const length2 = data.length;
  const newData = new Array(length2 + 2);
  let readIndex = 0;
  let writeIndex = 0;
  while (readIndex < idx) newData[writeIndex++] = data[readIndex++];
  newData[writeIndex++] = key;
  newData[writeIndex++] = val;
  while (readIndex < length2) newData[writeIndex++] = data[readIndex++];
  return new Node(generation, node.datamap | bit, node.nodemap, newData);
}
function copyAndRemovePair(node, generation, bit, idx) {
  node = copyNode(node, generation);
  const data = node.data;
  const length2 = data.length;
  for (let w = idx, r = idx + 2; r < length2; ++r, ++w) {
    data[w] = data[r];
  }
  data.pop();
  data.pop();
  node.datamap ^= bit;
  return node;
}
function make() {
  return emptyDict;
}
function from(iterable) {
  let transient = toTransient(emptyDict);
  for (const [key, value4] of iterable) {
    transient = destructiveTransientInsert(key, value4, transient);
  }
  return fromTransient(transient);
}
function size(dict4) {
  return dict4.size;
}
function get(dict4, key) {
  const result = lookup(dict4.root, key, getHash(key));
  return result !== noElementMarker ? Result$Ok(result) : errorNil;
}
function has(dict4, key) {
  return lookup(dict4.root, key, getHash(key)) !== noElementMarker;
}
function lookup(node, key, hash) {
  for (let shift = 0; shift < 32; shift += bits) {
    const data = node.data;
    const bit = hashbit(hash, shift);
    if (node.nodemap & bit) {
      node = data[data.length - 1 - index(node.nodemap, bit)];
    } else if (node.datamap & bit) {
      const dataidx = Math.imul(index(node.datamap, bit), 2);
      return isEqual(key, data[dataidx]) ? data[dataidx + 1] : noElementMarker;
    } else {
      return noElementMarker;
    }
  }
  const overflow = node.data;
  for (let i = 0; i < overflow.length; i += 2) {
    if (isEqual(key, overflow[i])) {
      return overflow[i + 1];
    }
  }
  return noElementMarker;
}
function toTransient(dict4) {
  return {
    generation: nextGeneration(dict4),
    root: dict4.root,
    size: dict4.size,
    dict: dict4
  };
}
function fromTransient(transient) {
  if (transient.root === transient.dict.root) {
    return transient.dict;
  }
  return new Dict(transient.size, transient.root);
}
function nextGeneration(dict4) {
  const root = dict4.root;
  if (root.generation < Number.MAX_SAFE_INTEGER) {
    return root.generation + 1;
  }
  const queue = [root];
  while (queue.length) {
    const node = queue.pop();
    node.generation = 0;
    const nodeStart = node.data.length - popcount(node.nodemap);
    for (let i = nodeStart; i < node.data.length; ++i) {
      queue.push(node.data[i]);
    }
  }
  return 1;
}
var globalTransient = /* @__PURE__ */ toTransient(emptyDict);
function insert(dict4, key, value4) {
  globalTransient.generation = nextGeneration(dict4);
  globalTransient.size = dict4.size;
  const hash = getHash(key);
  const root = insertIntoNode(globalTransient, dict4.root, key, value4, hash, 0);
  if (root === dict4.root) {
    return dict4;
  }
  return new Dict(globalTransient.size, root);
}
function destructiveTransientInsert(key, value4, transient) {
  const hash = getHash(key);
  transient.root = insertIntoNode(transient, transient.root, key, value4, hash, 0);
  return transient;
}
function destructiveTransientUpdateWith(key, fun, value4, transient) {
  const hash = getHash(key);
  const existing = lookup(transient.root, key, hash);
  if (existing !== noElementMarker) {
    value4 = fun(existing);
  }
  transient.root = insertIntoNode(transient, transient.root, key, value4, hash, 0);
  return transient;
}
function insertIntoNode(transient, node, key, value4, hash, shift) {
  const data = node.data;
  const generation = transient.generation;
  if (shift > 32) {
    for (let i = 0; i < data.length; i += 2) {
      if (isEqual(key, data[i])) {
        return copyAndSet(node, generation, i + 1, value4);
      }
    }
    transient.size += 1;
    return copyAndInsertPair(node, generation, 0, data.length, key, value4);
  }
  const bit = hashbit(hash, shift);
  if (node.nodemap & bit) {
    const nodeidx2 = data.length - 1 - index(node.nodemap, bit);
    let child2 = data[nodeidx2];
    child2 = insertIntoNode(transient, child2, key, value4, hash, shift + bits);
    return copyAndSet(node, generation, nodeidx2, child2);
  }
  const dataidx = Math.imul(index(node.datamap, bit), 2);
  if ((node.datamap & bit) === 0) {
    transient.size += 1;
    return copyAndInsertPair(node, generation, bit, dataidx, key, value4);
  }
  if (isEqual(key, data[dataidx])) {
    return copyAndSet(node, generation, dataidx + 1, value4);
  }
  const childShift = shift + bits;
  let child = emptyNode;
  child = insertIntoNode(transient, child, key, value4, hash, childShift);
  const key2 = data[dataidx];
  const value22 = data[dataidx + 1];
  const hash2 = getHash(key2);
  child = insertIntoNode(transient, child, key2, value22, hash2, childShift);
  transient.size -= 1;
  const length2 = data.length;
  const nodeidx = length2 - 1 - index(node.nodemap, bit);
  const newData = new Array(length2 - 1);
  let readIndex = 0;
  let writeIndex = 0;
  while (readIndex < dataidx) newData[writeIndex++] = data[readIndex++];
  readIndex += 2;
  while (readIndex <= nodeidx) newData[writeIndex++] = data[readIndex++];
  newData[writeIndex++] = child;
  while (readIndex < length2) newData[writeIndex++] = data[readIndex++];
  return new Node(generation, node.datamap ^ bit, node.nodemap | bit, newData);
}
function destructiveTransientDelete(key, transient) {
  const hash = getHash(key);
  transient.root = deleteFromNode(transient, transient.root, key, hash, 0);
  return transient;
}
function deleteFromNode(transient, node, key, hash, shift) {
  const data = node.data;
  const generation = transient.generation;
  if (shift > 32) {
    for (let i = 0; i < data.length; i += 2) {
      if (isEqual(key, data[i])) {
        transient.size -= 1;
        return copyAndRemovePair(node, generation, 0, i);
      }
    }
    return node;
  }
  const bit = hashbit(hash, shift);
  const dataidx = Math.imul(index(node.datamap, bit), 2);
  if ((node.nodemap & bit) !== 0) {
    const nodeidx = data.length - 1 - index(node.nodemap, bit);
    let child = data[nodeidx];
    child = deleteFromNode(transient, child, key, hash, shift + bits);
    if (child.nodemap !== 0 || child.data.length > 2) {
      return copyAndSet(node, generation, nodeidx, child);
    }
    const length2 = data.length;
    const newData = new Array(length2 + 1);
    let readIndex = 0;
    let writeIndex = 0;
    while (readIndex < dataidx) newData[writeIndex++] = data[readIndex++];
    newData[writeIndex++] = child.data[0];
    newData[writeIndex++] = child.data[1];
    while (readIndex < nodeidx) newData[writeIndex++] = data[readIndex++];
    readIndex++;
    while (readIndex < length2) newData[writeIndex++] = data[readIndex++];
    return new Node(generation, node.datamap | bit, node.nodemap ^ bit, newData);
  }
  if ((node.datamap & bit) === 0 || !isEqual(key, data[dataidx])) {
    return node;
  }
  transient.size -= 1;
  return copyAndRemovePair(node, generation, bit, dataidx);
}
function fold(dict4, state, fun) {
  const queue = [dict4.root];
  while (queue.length) {
    const node = queue.pop();
    const data = node.data;
    const edgesStart = data.length - popcount(node.nodemap);
    for (let i = 0; i < edgesStart; i += 2) {
      state = fun(state, data[i], data[i + 1]);
    }
    for (let i = edgesStart; i < data.length; ++i) {
      queue.push(data[i]);
    }
  }
  return state;
}
function popcount(n) {
  n -= n >>> 1 & 1431655765;
  n = (n & 858993459) + (n >>> 2 & 858993459);
  return Math.imul(n + (n >>> 4) & 252645135, 16843009) >>> 24;
}
function index(bitmap, bit) {
  return popcount(bitmap & bit - 1);
}
function hashbit(hash, shift) {
  return 1 << (hash >>> shift & mask);
}

// build/dev/javascript/gleam_stdlib/gleam/dict.mjs
function is_empty(dict4) {
  return size(dict4) === 0;
}
function to_list(dict4) {
  return fold(
    dict4,
    List$Empty$const,
    (acc, key, value4) => {
      return prepend([key, value4], acc);
    }
  );
}
function from_list_loop(loop$transient, loop$list) {
  while (true) {
    let transient = loop$transient;
    let list3 = loop$list;
    if (list3 instanceof Empty) {
      return fromTransient(transient);
    } else {
      let rest = list3.tail;
      let key = list3.head[0];
      let value4 = list3.head[1];
      loop$transient = destructiveTransientInsert(key, value4, transient);
      loop$list = rest;
    }
  }
}
function from_list(list3) {
  return from_list_loop(toTransient(make()), list3);
}
function keys(dict4) {
  return fold(
    dict4,
    List$Empty$const,
    (acc, key, _) => {
      return prepend(key, acc);
    }
  );
}
function values(dict4) {
  return fold(
    dict4,
    List$Empty$const,
    (acc, _, value4) => {
      return prepend(value4, acc);
    }
  );
}
function do_filter(f, dict4) {
  let _pipe = toTransient(make());
  let _pipe$1 = fold(
    dict4,
    _pipe,
    (transient, key, value4) => {
      let $ = f(key, value4);
      if ($) {
        return destructiveTransientInsert(key, value4, transient);
      } else {
        return transient;
      }
    }
  );
  return fromTransient(_pipe$1);
}
function filter(dict4, predicate) {
  return do_filter(predicate, dict4);
}
function do_combine(combine2, left, right) {
  let _block;
  let $1 = size(left) >= size(right);
  if ($1) {
    _block = [left, right, combine2];
  } else {
    _block = [right, left, (k, l, r) => {
      return combine2(k, r, l);
    }];
  }
  let $ = _block;
  let big = $[0];
  let small = $[1];
  let combine$1 = $[2];
  let _pipe = toTransient(big);
  let _pipe$1 = fold(
    small,
    _pipe,
    (transient, key, value4) => {
      let update2 = (existing) => {
        return combine$1(key, existing, value4);
      };
      return destructiveTransientUpdateWith(key, update2, value4, transient);
    }
  );
  return fromTransient(_pipe$1);
}
function combine(dict4, other, fun) {
  return do_combine((_, l, r) => {
    return fun(l, r);
  }, dict4, other);
}
function merge(dict4, new_entries) {
  return combine(dict4, new_entries, (_, new_entry) => {
    return new_entry;
  });
}
function delete$(dict4, key) {
  let _pipe = toTransient(dict4);
  let _pipe$1 = ((_capture) => {
    return destructiveTransientDelete(key, _capture);
  })(
    _pipe
  );
  return fromTransient(_pipe$1);
}

// build/dev/javascript/gleam_stdlib/gleam/list.mjs
var Ascending = class extends CustomType {
};
var Sorting$Ascending$const = new Ascending();
var Descending = class extends CustomType {
};
var Sorting$Descending$const = new Descending();
function reverse_and_prepend(loop$prefix, loop$suffix) {
  while (true) {
    let prefix = loop$prefix;
    let suffix = loop$suffix;
    if (prefix instanceof Empty) {
      return suffix;
    } else {
      let first$1 = prefix.head;
      let rest$1 = prefix.tail;
      loop$prefix = rest$1;
      loop$suffix = prepend(first$1, suffix);
    }
  }
}
function reverse(list3) {
  return reverse_and_prepend(list3, List$Empty$const);
}
function map_loop(loop$list, loop$fun, loop$acc) {
  while (true) {
    let list3 = loop$list;
    let fun = loop$fun;
    let acc = loop$acc;
    if (list3 instanceof Empty) {
      return reverse(acc);
    } else {
      let first$1 = list3.head;
      let rest$1 = list3.tail;
      loop$list = rest$1;
      loop$fun = fun;
      loop$acc = prepend(fun(first$1), acc);
    }
  }
}
function map2(list3, fun) {
  return map_loop(list3, fun, List$Empty$const);
}
function try_map_loop(loop$list, loop$fun, loop$acc) {
  while (true) {
    let list3 = loop$list;
    let fun = loop$fun;
    let acc = loop$acc;
    if (list3 instanceof Empty) {
      return new Ok(reverse(acc));
    } else {
      let first$1 = list3.head;
      let rest$1 = list3.tail;
      let $ = fun(first$1);
      if ($ instanceof Ok) {
        let first$2 = $[0];
        loop$list = rest$1;
        loop$fun = fun;
        loop$acc = prepend(first$2, acc);
      } else {
        return $;
      }
    }
  }
}
function try_map(list3, fun) {
  return try_map_loop(list3, fun, List$Empty$const);
}
function append_loop(loop$first, loop$second) {
  while (true) {
    let first = loop$first;
    let second = loop$second;
    if (first instanceof Empty) {
      return second;
    } else {
      let first$1 = first.head;
      let rest$1 = first.tail;
      loop$first = rest$1;
      loop$second = prepend(first$1, second);
    }
  }
}
function append(first, second) {
  return append_loop(reverse(first), second);
}
function fold2(loop$list, loop$initial, loop$fun) {
  while (true) {
    let list3 = loop$list;
    let initial = loop$initial;
    let fun = loop$fun;
    if (list3 instanceof Empty) {
      return initial;
    } else {
      let first$1 = list3.head;
      let rest$1 = list3.tail;
      loop$list = rest$1;
      loop$initial = fun(initial, first$1);
      loop$fun = fun;
    }
  }
}
function all(loop$list, loop$predicate) {
  while (true) {
    let list3 = loop$list;
    let predicate = loop$predicate;
    if (list3 instanceof Empty) {
      return true;
    } else {
      let first$1 = list3.head;
      let rest$1 = list3.tail;
      let $ = predicate(first$1);
      if ($) {
        loop$list = rest$1;
        loop$predicate = predicate;
      } else {
        return $;
      }
    }
  }
}
function unique_loop(loop$list, loop$seen, loop$acc) {
  while (true) {
    let list3 = loop$list;
    let seen = loop$seen;
    let acc = loop$acc;
    if (list3 instanceof Empty) {
      return reverse(acc);
    } else {
      let first$1 = list3.head;
      let rest$1 = list3.tail;
      let $ = has(seen, first$1);
      if ($) {
        loop$list = rest$1;
        loop$seen = seen;
        loop$acc = acc;
      } else {
        loop$list = rest$1;
        loop$seen = insert(seen, first$1, void 0);
        loop$acc = prepend(first$1, acc);
      }
    }
  }
}
function unique(list3) {
  return unique_loop(list3, make(), List$Empty$const);
}
function merge_descendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list22 = loop$list2;
    let compare4 = loop$compare;
    let acc = loop$acc;
    if (list1 instanceof Empty) {
      let list3 = list22;
      return reverse_and_prepend(list3, acc);
    } else if (list22 instanceof Empty) {
      let list3 = list1;
      return reverse_and_prepend(list3, acc);
    } else {
      let first1 = list1.head;
      let rest1 = list1.tail;
      let first2 = list22.head;
      let rest2 = list22.tail;
      let $ = compare4(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare4;
        loop$acc = prepend(first2, acc);
      } else if ($ instanceof Eq) {
        loop$list1 = rest1;
        loop$list2 = list22;
        loop$compare = compare4;
        loop$acc = prepend(first1, acc);
      } else {
        loop$list1 = rest1;
        loop$list2 = list22;
        loop$compare = compare4;
        loop$acc = prepend(first1, acc);
      }
    }
  }
}
function merge_descending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences2 = loop$sequences;
    let compare4 = loop$compare;
    let acc = loop$acc;
    if (sequences2 instanceof Empty) {
      return reverse(acc);
    } else {
      let $ = sequences2.tail;
      if ($ instanceof Empty) {
        let sequence = sequences2.head;
        return reverse(prepend(reverse(sequence), acc));
      } else {
        let descending1 = sequences2.head;
        let descending2 = $.head;
        let rest$1 = $.tail;
        let ascending = merge_descendings(
          descending1,
          descending2,
          compare4,
          List$Empty$const
        );
        loop$sequences = rest$1;
        loop$compare = compare4;
        loop$acc = prepend(ascending, acc);
      }
    }
  }
}
function merge_ascendings(loop$list1, loop$list2, loop$compare, loop$acc) {
  while (true) {
    let list1 = loop$list1;
    let list22 = loop$list2;
    let compare4 = loop$compare;
    let acc = loop$acc;
    if (list1 instanceof Empty) {
      let list3 = list22;
      return reverse_and_prepend(list3, acc);
    } else if (list22 instanceof Empty) {
      let list3 = list1;
      return reverse_and_prepend(list3, acc);
    } else {
      let first1 = list1.head;
      let rest1 = list1.tail;
      let first2 = list22.head;
      let rest2 = list22.tail;
      let $ = compare4(first1, first2);
      if ($ instanceof Lt) {
        loop$list1 = rest1;
        loop$list2 = list22;
        loop$compare = compare4;
        loop$acc = prepend(first1, acc);
      } else if ($ instanceof Eq) {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare4;
        loop$acc = prepend(first2, acc);
      } else {
        loop$list1 = list1;
        loop$list2 = rest2;
        loop$compare = compare4;
        loop$acc = prepend(first2, acc);
      }
    }
  }
}
function merge_ascending_pairs(loop$sequences, loop$compare, loop$acc) {
  while (true) {
    let sequences2 = loop$sequences;
    let compare4 = loop$compare;
    let acc = loop$acc;
    if (sequences2 instanceof Empty) {
      return reverse(acc);
    } else {
      let $ = sequences2.tail;
      if ($ instanceof Empty) {
        let sequence = sequences2.head;
        return reverse(prepend(reverse(sequence), acc));
      } else {
        let ascending1 = sequences2.head;
        let ascending2 = $.head;
        let rest$1 = $.tail;
        let descending = merge_ascendings(
          ascending1,
          ascending2,
          compare4,
          List$Empty$const
        );
        loop$sequences = rest$1;
        loop$compare = compare4;
        loop$acc = prepend(descending, acc);
      }
    }
  }
}
function merge_all(loop$sequences, loop$direction, loop$compare) {
  while (true) {
    let sequences2 = loop$sequences;
    let direction = loop$direction;
    let compare4 = loop$compare;
    if (sequences2 instanceof Empty) {
      return sequences2;
    } else if (direction instanceof Ascending) {
      let $ = sequences2.tail;
      if ($ instanceof Empty) {
        let sequence = sequences2.head;
        return sequence;
      } else {
        let sequences$1 = merge_ascending_pairs(
          sequences2,
          compare4,
          List$Empty$const
        );
        loop$sequences = sequences$1;
        loop$direction = Sorting$Descending$const;
        loop$compare = compare4;
      }
    } else {
      let $ = sequences2.tail;
      if ($ instanceof Empty) {
        let sequence = sequences2.head;
        return reverse(sequence);
      } else {
        let sequences$1 = merge_descending_pairs(
          sequences2,
          compare4,
          List$Empty$const
        );
        loop$sequences = sequences$1;
        loop$direction = Sorting$Ascending$const;
        loop$compare = compare4;
      }
    }
  }
}
function sequences(loop$list, loop$compare, loop$growing, loop$direction, loop$prev, loop$acc) {
  while (true) {
    let list3 = loop$list;
    let compare4 = loop$compare;
    let growing = loop$growing;
    let direction = loop$direction;
    let prev = loop$prev;
    let acc = loop$acc;
    let growing$1 = prepend(prev, growing);
    if (list3 instanceof Empty) {
      if (direction instanceof Ascending) {
        return prepend(reverse(growing$1), acc);
      } else {
        return prepend(growing$1, acc);
      }
    } else {
      let new$1 = list3.head;
      let rest$1 = list3.tail;
      let $ = compare4(prev, new$1);
      if (direction instanceof Ascending) {
        if ($ instanceof Lt) {
          loop$list = rest$1;
          loop$compare = compare4;
          loop$growing = growing$1;
          loop$direction = direction;
          loop$prev = new$1;
          loop$acc = acc;
        } else if ($ instanceof Eq) {
          loop$list = rest$1;
          loop$compare = compare4;
          loop$growing = growing$1;
          loop$direction = direction;
          loop$prev = new$1;
          loop$acc = acc;
        } else {
          let _block;
          if (direction instanceof Ascending) {
            _block = prepend(reverse(growing$1), acc);
          } else {
            _block = prepend(growing$1, acc);
          }
          let acc$1 = _block;
          if (rest$1 instanceof Empty) {
            return prepend(toList([new$1]), acc$1);
          } else {
            let next = rest$1.head;
            let rest$2 = rest$1.tail;
            let _block$1;
            let $1 = compare4(new$1, next);
            if ($1 instanceof Lt) {
              _block$1 = Sorting$Ascending$const;
            } else if ($1 instanceof Eq) {
              _block$1 = Sorting$Ascending$const;
            } else {
              _block$1 = Sorting$Descending$const;
            }
            let direction$1 = _block$1;
            loop$list = rest$2;
            loop$compare = compare4;
            loop$growing = toList([new$1]);
            loop$direction = direction$1;
            loop$prev = next;
            loop$acc = acc$1;
          }
        }
      } else if ($ instanceof Lt) {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1 instanceof Empty) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare4(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = Sorting$Ascending$const;
          } else if ($1 instanceof Eq) {
            _block$1 = Sorting$Ascending$const;
          } else {
            _block$1 = Sorting$Descending$const;
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare4;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else if ($ instanceof Eq) {
        let _block;
        if (direction instanceof Ascending) {
          _block = prepend(reverse(growing$1), acc);
        } else {
          _block = prepend(growing$1, acc);
        }
        let acc$1 = _block;
        if (rest$1 instanceof Empty) {
          return prepend(toList([new$1]), acc$1);
        } else {
          let next = rest$1.head;
          let rest$2 = rest$1.tail;
          let _block$1;
          let $1 = compare4(new$1, next);
          if ($1 instanceof Lt) {
            _block$1 = Sorting$Ascending$const;
          } else if ($1 instanceof Eq) {
            _block$1 = Sorting$Ascending$const;
          } else {
            _block$1 = Sorting$Descending$const;
          }
          let direction$1 = _block$1;
          loop$list = rest$2;
          loop$compare = compare4;
          loop$growing = toList([new$1]);
          loop$direction = direction$1;
          loop$prev = next;
          loop$acc = acc$1;
        }
      } else {
        loop$list = rest$1;
        loop$compare = compare4;
        loop$growing = growing$1;
        loop$direction = direction;
        loop$prev = new$1;
        loop$acc = acc;
      }
    }
  }
}
function sort(list3, compare4) {
  if (list3 instanceof Empty) {
    return list3;
  } else {
    let $ = list3.tail;
    if ($ instanceof Empty) {
      return list3;
    } else {
      let x = list3.head;
      let y = $.head;
      let rest$1 = $.tail;
      let _block;
      let $1 = compare4(x, y);
      if ($1 instanceof Lt) {
        _block = Sorting$Ascending$const;
      } else if ($1 instanceof Eq) {
        _block = Sorting$Ascending$const;
      } else {
        _block = Sorting$Descending$const;
      }
      let direction = _block;
      let sequences$1 = sequences(
        rest$1,
        compare4,
        toList([x]),
        direction,
        y,
        List$Empty$const
      );
      return merge_all(sequences$1, Sorting$Ascending$const, compare4);
    }
  }
}

// build/dev/javascript/gleam_stdlib/gleam/dynamic/decode.mjs
var DecodeError = class extends CustomType {
  constructor(expected, found, path) {
    super();
    this.expected = expected;
    this.found = found;
    this.path = path;
  }
};
var DecodeError$DecodeError = (expected, found, path) => new DecodeError(expected, found, path);
var Decoder = class extends CustomType {
  constructor(function$) {
    super();
    this.function = function$;
  }
};
var float2 = /* @__PURE__ */ new Decoder(decode_float);
var int2 = /* @__PURE__ */ new Decoder(decode_int);
var string2 = /* @__PURE__ */ new Decoder(decode_string);
function run(data, decoder3) {
  let $ = decoder3.function(data);
  let maybe_invalid_data = $[0];
  let errors = $[1];
  if (errors instanceof Empty) {
    return new Ok(maybe_invalid_data);
  } else {
    return new Error(errors);
  }
}
function run_dynamic_function(data, name, f) {
  let $ = f(data);
  if ($ instanceof Ok) {
    let data$1 = $[0];
    return [data$1, List$Empty$const];
  } else {
    let placeholder = $[0];
    return [
      placeholder,
      toList([new DecodeError(name, classify_dynamic(data), List$Empty$const)])
    ];
  }
}
function decode_float(data) {
  return run_dynamic_function(data, "Float", float);
}
function map3(decoder3, transformer) {
  return new Decoder(
    (d) => {
      let $ = decoder3.function(d);
      let data = $[0];
      let errors = $[1];
      return [transformer(data), errors];
    }
  );
}
function decode_int(data) {
  return run_dynamic_function(data, "Int", int);
}
function decode_string(data) {
  return run_dynamic_function(data, "String", string);
}
function run_decoders(loop$data, loop$failure, loop$decoders) {
  while (true) {
    let data = loop$data;
    let failure2 = loop$failure;
    let decoders = loop$decoders;
    if (decoders instanceof Empty) {
      return failure2;
    } else {
      let decoder3 = decoders.head;
      let decoders$1 = decoders.tail;
      let $ = decoder3.function(data);
      let layer = $;
      let errors = $[1];
      if (errors instanceof Empty) {
        return layer;
      } else {
        loop$data = data;
        loop$failure = failure2;
        loop$decoders = decoders$1;
      }
    }
  }
}
function one_of(first, alternatives) {
  return new Decoder(
    (dynamic_data) => {
      let $ = first.function(dynamic_data);
      let layer = $;
      let errors = $[1];
      if (errors instanceof Empty) {
        return layer;
      } else {
        return run_decoders(dynamic_data, layer, alternatives);
      }
    }
  );
}
function path_segment_to_string(key) {
  let decoder3 = one_of(
    string2,
    toList([
      (() => {
        let _pipe = int2;
        return map3(_pipe, to_string);
      })(),
      (() => {
        let _pipe = float2;
        return map3(_pipe, float_to_string);
      })()
    ])
  );
  let $ = run(key, decoder3);
  if ($ instanceof Ok) {
    let key$1 = $[0];
    return key$1;
  } else {
    return "<" + classify_dynamic(key) + ">";
  }
}
function push_path(layer, path) {
  let path$1 = map2(
    path,
    (key) => {
      let _pipe = key;
      let _pipe$1 = identity(_pipe);
      return path_segment_to_string(_pipe$1);
    }
  );
  let errors = map2(
    layer[1],
    (error) => {
      return new DecodeError(
        error.expected,
        error.found,
        append(path$1, error.path)
      );
    }
  );
  return [layer[0], errors];
}
function list2(inner) {
  return new Decoder(
    (data) => {
      return list(
        data,
        inner.function,
        (p, k) => {
          return push_path(p, toList([k]));
        },
        0,
        List$Empty$const
      );
    }
  );
}
function index3(loop$path, loop$position, loop$inner, loop$data, loop$handle_miss) {
  while (true) {
    let path = loop$path;
    let position = loop$position;
    let inner = loop$inner;
    let data = loop$data;
    let handle_miss = loop$handle_miss;
    if (path instanceof Empty) {
      let _pipe = data;
      let _pipe$1 = inner(_pipe);
      return push_path(_pipe$1, reverse(position));
    } else {
      let key = path.head;
      let path$1 = path.tail;
      let $ = index2(data, key);
      if ($ instanceof Ok) {
        let $1 = $[0];
        if ($1 instanceof Some) {
          let data$1 = $1[0];
          loop$path = path$1;
          loop$position = prepend(key, position);
          loop$inner = inner;
          loop$data = data$1;
          loop$handle_miss = handle_miss;
        } else {
          return handle_miss(data, prepend(key, position));
        }
      } else {
        let kind = $[0];
        let $1 = inner(data);
        let default$ = $1[0];
        let _pipe = [
          default$,
          toList([
            new DecodeError(kind, classify_dynamic(data), List$Empty$const)
          ])
        ];
        return push_path(_pipe, reverse(position));
      }
    }
  }
}
function subfield(field_path, field_decoder, next) {
  return new Decoder(
    (data) => {
      let $ = index3(
        field_path,
        List$Empty$const,
        field_decoder.function,
        data,
        (data2, position) => {
          let $12 = field_decoder.function(data2);
          let default$ = $12[0];
          let _pipe = [
            default$,
            toList([new DecodeError("Field", "Nothing", List$Empty$const)])
          ];
          return push_path(_pipe, reverse(position));
        }
      );
      let out = $[0];
      let errors1 = $[1];
      let $1 = next(out).function(data);
      let out$1 = $1[0];
      let errors2 = $1[1];
      return [out$1, append(errors1, errors2)];
    }
  );
}
function at(path, inner) {
  return new Decoder(
    (data) => {
      return index3(
        path,
        List$Empty$const,
        inner.function,
        data,
        (data2, position) => {
          let $ = inner.function(data2);
          let default$ = $[0];
          let _pipe = [
            default$,
            toList([new DecodeError("Field", "Nothing", List$Empty$const)])
          ];
          return push_path(_pipe, reverse(position));
        }
      );
    }
  );
}
function success(data) {
  return new Decoder((_) => {
    return [data, List$Empty$const];
  });
}
function decode_error(expected, found) {
  return toList([
    new DecodeError(expected, classify_dynamic(found), List$Empty$const)
  ]);
}
function field(field_name, field_decoder, next) {
  return subfield(toList([field_name]), field_decoder, next);
}
function optional_field(key, default$, field_decoder, next) {
  return new Decoder(
    (data) => {
      let _block;
      let _block$1;
      let $1 = index2(data, key);
      if ($1 instanceof Ok) {
        let $22 = $1[0];
        if ($22 instanceof Some) {
          let data$1 = $22[0];
          _block$1 = field_decoder.function(data$1);
        } else {
          _block$1 = [default$, List$Empty$const];
        }
      } else {
        let kind = $1[0];
        _block$1 = [
          default$,
          toList([
            new DecodeError(kind, classify_dynamic(data), List$Empty$const)
          ])
        ];
      }
      let _pipe = _block$1;
      _block = push_path(_pipe, toList([key]));
      let $ = _block;
      let out = $[0];
      let errors1 = $[1];
      let $2 = next(out).function(data);
      let out$1 = $2[0];
      let errors2 = $2[1];
      return [out$1, append(errors1, errors2)];
    }
  );
}
function fold_dict(acc, key, value4, key_decoder, value_decoder) {
  let $ = key_decoder(key);
  let $1 = $[1];
  if ($1 instanceof Empty) {
    let key_decoded = $[0];
    let $2 = value_decoder(value4);
    let $3 = $2[1];
    if ($3 instanceof Empty) {
      let value$1 = $2[0];
      let dict$1 = insert(acc[0], key_decoded, value$1);
      return [dict$1, acc[1]];
    } else {
      let errors = $3;
      let key_identifier = path_segment_to_string(key);
      return push_path([make(), errors], toList([key_identifier]));
    }
  } else {
    let errors = $1;
    return push_path([make(), errors], toList(["keys"]));
  }
}
function dict2(key, value4) {
  return new Decoder(
    (data) => {
      let $ = dict(data);
      if ($ instanceof Ok) {
        let dict$1 = $[0];
        return fold(
          dict$1,
          [make(), List$Empty$const],
          (a, k, v) => {
            let $1 = a[1];
            if ($1 instanceof Empty) {
              return fold_dict(a, k, v, key.function, value4.function);
            } else {
              return a;
            }
          }
        );
      } else {
        return [make(), decode_error("Dict", data)];
      }
    }
  );
}
function then$(decoder3, next) {
  return new Decoder(
    (dynamic_data) => {
      let $ = decoder3.function(dynamic_data);
      let data = $[0];
      let errors = $[1];
      let decoder$1 = next(data);
      let $1 = decoder$1.function(dynamic_data);
      let layer = $1;
      let data$1 = $1[0];
      if (errors instanceof Empty) {
        return layer;
      } else {
        return [data$1, errors];
      }
    }
  );
}
function failure(placeholder, name) {
  return new Decoder((d) => {
    return [placeholder, decode_error(name, d)];
  });
}

// build/dev/javascript/gleam_stdlib/gleam_stdlib.mjs
function identity(x) {
  return x;
}
function to_string(term) {
  return term.toString();
}
function less_than(a, b) {
  return a < b;
}
var unicode_whitespaces = [
  " ",
  // Space
  "	",
  // Horizontal tab
  "\n",
  // Line feed
  "\v",
  // Vertical tab
  "\f",
  // Form feed
  "\r",
  // Carriage return
  "\x85",
  // Next line
  "\u2028",
  // Line separator
  "\u2029"
  // Paragraph separator
].join("");
var trim_start_regex = /* @__PURE__ */ new RegExp(
  `^[${unicode_whitespaces}]*`
);
var trim_end_regex = /* @__PURE__ */ new RegExp(`[${unicode_whitespaces}]*$`);
function classify_dynamic(data) {
  if (typeof data === "string") {
    return "String";
  } else if (typeof data === "boolean") {
    return "Bool";
  } else if (isResult(data)) {
    return "Result";
  } else if (isList(data)) {
    return "List";
  } else if (data instanceof BitArray) {
    return "BitArray";
  } else if (data instanceof Dict) {
    return "Dict";
  } else if (Number.isInteger(data)) {
    return "Int";
  } else if (Array.isArray(data)) {
    return `Array`;
  } else if (typeof data === "number") {
    return "Float";
  } else if (data === null) {
    return "Nil";
  } else if (data === void 0) {
    return "Nil";
  } else {
    const type = typeof data;
    return type.charAt(0).toUpperCase() + type.slice(1);
  }
}
var MIN_I32 = -(2 ** 31);
var MAX_I32 = 2 ** 31 - 1;
var U32 = 2 ** 32;
var MAX_SAFE = Number.MAX_SAFE_INTEGER;
var MIN_SAFE = Number.MIN_SAFE_INTEGER;
function float_to_string(float3) {
  const string4 = float3.toString().replace("+", "");
  if (string4.indexOf(".") >= 0) {
    return string4;
  } else {
    const index4 = string4.indexOf("e");
    if (index4 >= 0) {
      return string4.slice(0, index4) + ".0" + string4.slice(index4);
    } else {
      return string4 + ".0";
    }
  }
}
function index2(data, key) {
  if (data instanceof Dict) {
    const result = get(data, key);
    return Result$Ok(result.isOk() ? new Some(result[0]) : new None());
  }
  if (data instanceof WeakMap || data instanceof Map) {
    const token2 = {};
    const entry = data.get(key, token2);
    if (entry === token2) return Result$Ok(new None());
    return Result$Ok(new Some(entry));
  }
  const key_is_int = Number.isInteger(key);
  if (key_is_int && key >= 0 && key < 8 && isList(data)) {
    let i = 0;
    for (const value4 of data) {
      if (i === key) return Result$Ok(new Some(value4));
      i++;
    }
    return Result$Error("Indexable");
  }
  if (key_is_int && Array.isArray(data) || data && typeof data === "object" || data && Object.getPrototypeOf(data) === Object.prototype) {
    if (key in data) return Result$Ok(new Some(data[key]));
    return Result$Ok(new None());
  }
  return Result$Error(key_is_int ? "Indexable" : "Dict");
}
function list(data, decode2, pushPath, index4, emptyList) {
  if (!(isList(data) || Array.isArray(data))) {
    const error = DecodeError$DecodeError("List", classify_dynamic(data), emptyList);
    return [emptyList, arrayToList([error])];
  }
  const decoded = [];
  for (const element of data) {
    const layer = decode2(element);
    const [out, errors] = layer;
    if (List$isNonEmpty(errors)) {
      const [_, errors2] = pushPath(layer, index4.toString());
      return [emptyList, errors2];
    }
    decoded.push(out);
    index4++;
  }
  return [arrayToList(decoded), emptyList];
}
function dict(data) {
  if (data instanceof Dict) {
    return Result$Ok(data);
  }
  if (data instanceof Map || data instanceof WeakMap) {
    return Result$Ok(from(data));
  }
  if (data == null) {
    return Result$Error("Dict");
  }
  if (typeof data !== "object") {
    return Result$Error("Dict");
  }
  const proto = Object.getPrototypeOf(data);
  if (proto === Object.prototype || proto === null) {
    return Result$Ok(from(Object.entries(data)));
  }
  return Result$Error("Dict");
}
function float(data) {
  if (typeof data === "number") return Result$Ok(data);
  return Result$Error(0);
}
function int(data) {
  if (Number.isInteger(data)) return Result$Ok(data);
  return Result$Error(0);
}
function string(data) {
  if (typeof data === "string") return Result$Ok(data);
  return Result$Error("");
}
function arrayToList(array3) {
  let list3 = List$Empty();
  let i = array3.length;
  while (i--) {
    list3 = List$NonEmpty(array3[i], list3);
  }
  return list3;
}
function isList(data) {
  return List$isEmpty(data) || List$isNonEmpty(data);
}
function isResult(data) {
  return Result$isOk(data) || Result$isError(data);
}

// build/dev/javascript/gleam_stdlib/gleam/int.mjs
function max(a, b) {
  let $ = a > b;
  if ($) {
    return a;
  } else {
    return b;
  }
}

// build/dev/javascript/gleam_stdlib/gleam/string_tree.mjs
var All = class extends CustomType {
};
var Direction$All$const = new All();

// build/dev/javascript/gleam_stdlib/gleam/string.mjs
var Leading = class extends CustomType {
};
var Direction$Leading$const = new Leading();
var Trailing = class extends CustomType {
};
var Direction$Trailing$const = new Trailing();
function compare2(a, b) {
  let $ = a === b;
  if ($) {
    return Order$Eq$const;
  } else {
    let $1 = less_than(a, b);
    if ($1) {
      return Order$Lt$const;
    } else {
      return Order$Gt$const;
    }
  }
}

// build/dev/javascript/gleam_stdlib/gleam/result.mjs
function is_ok(result) {
  if (result instanceof Ok) {
    return true;
  } else {
    return false;
  }
}
function map_error(result, fun) {
  if (result instanceof Ok) {
    return result;
  } else {
    let error = result[0];
    return new Error(fun(error));
  }
}
function try$(result, fun) {
  if (result instanceof Ok) {
    let x = result[0];
    return fun(x);
  } else {
    return result;
  }
}
function unwrap(result, default$) {
  if (result instanceof Ok) {
    let v = result[0];
    return v;
  } else {
    return default$;
  }
}
function replace_error(result, error) {
  if (result instanceof Ok) {
    return result;
  } else {
    return new Error(error);
  }
}

// build/dev/javascript/gleam_json/gleam_json_ffi.mjs
function json_to_string(json) {
  return JSON.stringify(json);
}
function object(entries) {
  return Object.fromEntries(entries);
}
function identity2(x) {
  return x;
}
function array(list3) {
  const array3 = [];
  while (List$isNonEmpty(list3)) {
    array3.push(List$NonEmpty$first(list3));
    list3 = List$NonEmpty$rest(list3);
  }
  return array3;
}
function decode(string4) {
  try {
    const result = JSON.parse(string4);
    return Result$Ok(result);
  } catch (err) {
    return Result$Error(getJsonDecodeError(err, string4));
  }
}
function getJsonDecodeError(stdErr, json) {
  if (isUnexpectedEndOfInput(stdErr)) return DecodeError$UnexpectedEndOfInput();
  return toUnexpectedByteError(stdErr, json);
}
function isUnexpectedEndOfInput(err) {
  const unexpectedEndOfInputRegex = /((unexpected (end|eof))|(end of data)|(unterminated string)|(json( parse error|\.parse)\: expected '(\:|\}|\])'))/i;
  return unexpectedEndOfInputRegex.test(err.message);
}
function toUnexpectedByteError(err, json) {
  let converters = [
    v8UnexpectedByteError,
    oldV8UnexpectedByteError,
    jsCoreUnexpectedByteError,
    spidermonkeyUnexpectedByteError
  ];
  for (let converter of converters) {
    let result = converter(err, json);
    if (result) return result;
  }
  return DecodeError$UnexpectedByte("");
}
function v8UnexpectedByteError(err) {
  const regex = /unexpected token '(.)', ".+" is not valid JSON/i;
  const match = regex.exec(err.message);
  if (!match) return null;
  const byte = toHex(match[1]);
  return DecodeError$UnexpectedByte(byte);
}
function oldV8UnexpectedByteError(err) {
  const regex = /unexpected token (.) in JSON at position (\d+)/i;
  const match = regex.exec(err.message);
  if (!match) return null;
  const byte = toHex(match[1]);
  return DecodeError$UnexpectedByte(byte);
}
function spidermonkeyUnexpectedByteError(err, json) {
  const regex = /(unexpected character|expected .*) at line (\d+) column (\d+)/i;
  const match = regex.exec(err.message);
  if (!match) return null;
  const line = Number(match[2]);
  const column = Number(match[3]);
  const position = getPositionFromMultiline(line, column, json);
  const byte = toHex(json[position]);
  return DecodeError$UnexpectedByte(byte);
}
function jsCoreUnexpectedByteError(err) {
  const regex = /unexpected (identifier|token) "(.)"/i;
  const match = regex.exec(err.message);
  if (!match) return null;
  const byte = toHex(match[2]);
  return DecodeError$UnexpectedByte(byte);
}
function toHex(char) {
  return "0x" + char.charCodeAt(0).toString(16).toUpperCase();
}
function getPositionFromMultiline(line, column, string4) {
  if (line === 1) return column - 1;
  let currentLn = 1;
  let position = 0;
  string4.split("").find((char, idx) => {
    if (char === "\n") currentLn += 1;
    if (currentLn === line) {
      position = idx + column;
      return true;
    }
    return false;
  });
  return position;
}

// build/dev/javascript/gleam_json/gleam/json.mjs
var UnexpectedEndOfInput = class extends CustomType {
};
var DecodeError$UnexpectedEndOfInput$const = new UnexpectedEndOfInput();
var DecodeError$UnexpectedEndOfInput = () => DecodeError$UnexpectedEndOfInput$const;
var UnexpectedByte = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var DecodeError$UnexpectedByte = ($0) => new UnexpectedByte($0);
var UnableToDecode = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
function do_parse(json, decoder3) {
  return try$(
    decode(json),
    (dynamic_value) => {
      let _pipe = run(dynamic_value, decoder3);
      return map_error(
        _pipe,
        (var0) => {
          return new UnableToDecode(var0);
        }
      );
    }
  );
}
function parse(json, decoder3) {
  return do_parse(json, decoder3);
}
function to_string2(json) {
  return json_to_string(json);
}
function string3(input) {
  return identity2(input);
}
function int3(input) {
  return identity2(input);
}
function object2(entries) {
  return object(entries);
}
function preprocessed_array(from2) {
  return array(from2);
}
function array2(entries, inner_type) {
  let _pipe = entries;
  let _pipe$1 = map2(_pipe, inner_type);
  return preprocessed_array(_pipe$1);
}
function dict3(dict4, keys3, values2) {
  return object2(
    fold(
      dict4,
      List$Empty$const,
      (acc, k, v) => {
        return prepend([keys3(k), values2(v)], acc);
      }
    )
  );
}

// build/dev/javascript/lattice_core/lattice_core/replica_id.mjs
var ReplicaId = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
function new$(id) {
  return new ReplicaId(id);
}
function to_string3(replica_id) {
  let s = replica_id[0];
  return s;
}
function compare3(a, b) {
  return compare2(to_string3(a), to_string3(b));
}
function to_json(replica_id) {
  return string3(to_string3(replica_id));
}
function decoder() {
  return map3(string2, new$);
}

// build/dev/javascript/lattice_core/lattice_core/version_vector.mjs
var Before = class extends CustomType {
};
var Order$Before$const = new Before();
var After = class extends CustomType {
};
var Order$After$const = new After();
var Concurrent = class extends CustomType {
};
var Order$Concurrent$const = new Concurrent();
var Equal = class extends CustomType {
};
var Order$Equal$const = new Equal();
var VersionVector = class extends CustomType {
  constructor(dict4) {
    super();
    this.dict = dict4;
  }
};
function new$2() {
  return new VersionVector(make());
}
function increment(vv, replica_id) {
  let dict4 = vv.dict;
  let current = unwrap(get(dict4, replica_id), 0);
  return new VersionVector(insert(dict4, replica_id, current + 1));
}
function get2(vv, replica_id) {
  let dict4 = vv.dict;
  return unwrap(get(dict4, replica_id), 0);
}
function is_empty2(vv) {
  let d = vv.dict;
  return is_empty(d);
}
function set_max(vv, replica_id, value4) {
  let d = vv.dict;
  let current = unwrap(get(d, replica_id), 0);
  let $ = value4 > current;
  if ($) {
    return new VersionVector(insert(d, replica_id, value4));
  } else {
    return vv;
  }
}
function merge2(a, b) {
  let da = a.dict;
  let db = b.dict;
  let merged = fold(
    db,
    da,
    (acc, k, v_b) => {
      let $ = get(acc, k);
      if ($ instanceof Ok) {
        let v_a = $[0];
        return insert(acc, k, max(v_a, v_b));
      } else {
        return insert(acc, k, v_b);
      }
    }
  );
  return new VersionVector(merged);
}
function to_json2(vv) {
  let d = vv.dict;
  return object2(
    toList([
      ["type", string3("version_vector")],
      ["v", int3(1)],
      [
        "state",
        object2(
          toList([
            [
              "clocks",
              dict3(
                d,
                (k) => {
                  return to_string3(k);
                },
                int3
              )
            ]
          ])
        )
      ]
    ])
  );
}
function from_json(json_string) {
  let state_decoder = field(
    "state",
    field(
      "clocks",
      dict2(decoder(), int2),
      (clocks) => {
        return success(new VersionVector(clocks));
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "version_vector" && version === 1;
    if ($1) {
      return parse(json_string, state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=version_vector and v=1",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}
function decoder2() {
  return field(
    "type",
    string2,
    (_) => {
      return field(
        "v",
        int2,
        (_2) => {
          return field(
            "state",
            field(
              "clocks",
              dict2(decoder(), int2),
              (clocks) => {
                return success(clocks);
              }
            ),
            (clocks) => {
              return success(new VersionVector(clocks));
            }
          );
        }
      );
    }
  );
}
function to_dict(vv) {
  let d = vv.dict;
  return d;
}
function from_dict(d) {
  return new VersionVector(d);
}

// build/dev/javascript/lattice_counters/lattice_counters/g_counter.mjs
var GCounter = class extends CustomType {
  constructor(dict4, self_id) {
    super();
    this.dict = dict4;
    this.self_id = self_id;
  }
};
function new$3(replica_id) {
  return new GCounter(make(), replica_id);
}
function merge_helper(loop$a, loop$b, loop$keys, loop$acc) {
  while (true) {
    let a = loop$a;
    let b = loop$b;
    let keys3 = loop$keys;
    let acc = loop$acc;
    if (keys3 instanceof Empty) {
      return acc;
    } else {
      let key = keys3.head;
      let rest = keys3.tail;
      let a_val = unwrap(get(a, key), 0);
      let b_val = unwrap(get(b, key), 0);
      let _block;
      let $ = a_val > b_val;
      if ($) {
        _block = a_val;
      } else {
        _block = b_val;
      }
      let merged_val = _block;
      let new_acc = insert(acc, key, merged_val);
      loop$a = a;
      loop$b = b;
      loop$keys = rest;
      loop$acc = new_acc;
    }
  }
}
function merge3(a, b) {
  let dict_a = a.dict;
  let self_id_a = a.self_id;
  let dict_b = b.dict;
  let a_keys = keys(dict_a);
  let b_keys = keys(dict_b);
  let all_keys = unique(append(a_keys, b_keys));
  let merged_dict = merge_helper(dict_a, dict_b, all_keys, make());
  return new GCounter(merged_dict, self_id_a);
}
function to_json3(counter) {
  let d = counter.dict;
  let self_id = counter.self_id;
  return object2(
    toList([
      ["type", string3("g_counter")],
      ["v", int3(1)],
      [
        "state",
        object2(
          toList([
            ["self_id", to_json(self_id)],
            [
              "counts",
              dict3(
                d,
                (k) => {
                  return to_string3(k);
                },
                int3
              )
            ]
          ])
        )
      ]
    ])
  );
}
function from_json2(json_string) {
  let state_decoder = field(
    "state",
    field(
      "self_id",
      decoder(),
      (self_id) => {
        let _block;
        let _pipe = int2;
        _block = then$(
          _pipe,
          (val) => {
            let $2 = val >= 0;
            if ($2) {
              return success(val);
            } else {
              return failure(val, "a non-negative integer");
            }
          }
        );
        let non_negative_int = _block;
        return field(
          "counts",
          dict2(decoder(), non_negative_int),
          (counts) => {
            return success(new GCounter(counts, self_id));
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "g_counter" && version === 1;
    if ($1) {
      return parse(json_string, state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=g_counter and v=1",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}
function to_parts(counter) {
  let dict4 = counter.dict;
  let self_id = counter.self_id;
  return [dict4, self_id];
}
function from_parts(dict4, self_id) {
  return new GCounter(dict4, self_id);
}

// build/dev/javascript/lattice_counters/lattice_counters/pn_counter.mjs
var PNCounter = class extends CustomType {
  constructor(positive, negative) {
    super();
    this.positive = positive;
    this.negative = negative;
  }
};
function new$4(replica_id) {
  return new PNCounter(new$3(replica_id), new$3(replica_id));
}
function merge4(a, b) {
  let positive_a = a.positive;
  let negative_a = a.negative;
  let positive_b = b.positive;
  let negative_b = b.negative;
  return new PNCounter(
    merge3(positive_a, positive_b),
    merge3(negative_a, negative_b)
  );
}
function to_json4(counter) {
  let positive = counter.positive;
  let negative = counter.negative;
  let $ = to_parts(positive);
  let pos_dict = $[0];
  let pos_id = $[1];
  let $1 = to_parts(negative);
  let neg_dict = $1[0];
  let neg_id = $1[1];
  return object2(
    toList([
      ["type", string3("pn_counter")],
      ["v", int3(1)],
      [
        "state",
        object2(
          toList([
            [
              "positive",
              object2(
                toList([
                  ["self_id", to_json(pos_id)],
                  [
                    "counts",
                    dict3(
                      pos_dict,
                      (k) => {
                        return to_string3(k);
                      },
                      int3
                    )
                  ]
                ])
              )
            ],
            [
              "negative",
              object2(
                toList([
                  ["self_id", to_json(neg_id)],
                  [
                    "counts",
                    dict3(
                      neg_dict,
                      (k) => {
                        return to_string3(k);
                      },
                      int3
                    )
                  ]
                ])
              )
            ]
          ])
        )
      ]
    ])
  );
}
function from_json3(json_string) {
  let g_counter_state_decoder = field(
    "self_id",
    decoder(),
    (self_id) => {
      let _block;
      let _pipe = int2;
      _block = then$(
        _pipe,
        (val) => {
          let $2 = val >= 0;
          if ($2) {
            return success(val);
          } else {
            return failure(val, "a non-negative integer");
          }
        }
      );
      let non_negative_int = _block;
      return field(
        "counts",
        dict2(decoder(), non_negative_int),
        (counts) => {
          return success(from_parts(counts, self_id));
        }
      );
    }
  );
  let state_decoder = field(
    "state",
    field(
      "positive",
      g_counter_state_decoder,
      (positive) => {
        return field(
          "negative",
          g_counter_state_decoder,
          (negative) => {
            return success(new PNCounter(positive, negative));
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "pn_counter" && version === 1;
    if ($1) {
      return parse(json_string, state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=pn_counter and v=1",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/gleam_stdlib/gleam/bool.mjs
function guard(requirement, consequence, alternative) {
  if (requirement) {
    return consequence;
  } else {
    return alternative();
  }
}

// build/dev/javascript/lattice_registers/lattice_registers/lww_register.mjs
var LWWRegister = class extends CustomType {
  constructor(value4, timestamp, replica_id) {
    super();
    this.value = value4;
    this.timestamp = timestamp;
    this.replica_id = replica_id;
  }
};
function new$5(val, timestamp, replica_id) {
  return new LWWRegister(val, timestamp, replica_id);
}
function merge5(a, b) {
  return guard(
    a.timestamp > b.timestamp,
    a,
    () => {
      return guard(
        a.timestamp < b.timestamp,
        b,
        () => {
          let $ = compare3(a.replica_id, b.replica_id);
          if ($ instanceof Lt) {
            return b;
          } else if ($ instanceof Eq) {
            return a;
          } else {
            return a;
          }
        }
      );
    }
  );
}
function to_json5(register) {
  return object2(
    toList([
      ["type", string3("lww_register")],
      ["v", int3(2)],
      [
        "state",
        object2(
          toList([
            ["value", string3(register.value)],
            ["timestamp", int3(register.timestamp)],
            [
              "replica_id",
              string3(to_string3(register.replica_id))
            ]
          ])
        )
      ]
    ])
  );
}
function from_json4(json_string) {
  let v2_state_decoder = field(
    "state",
    field(
      "value",
      string2,
      (value4) => {
        return field(
          "timestamp",
          int2,
          (timestamp) => {
            return optional_field(
              "replica_id",
              "",
              string2,
              (replica_id_str) => {
                return success(
                  new LWWRegister(
                    value4,
                    timestamp,
                    new$(replica_id_str)
                  )
                );
              }
            );
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "lww_register" && (version === 1 || version === 2);
    if ($1) {
      return parse(json_string, v2_state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=lww_register and v=1 or v=2",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/lattice_registers/lattice_registers/mv_register.mjs
var Tag = class extends CustomType {
  constructor(replica_id, counter) {
    super();
    this.replica_id = replica_id;
    this.counter = counter;
  }
};
var MVRegister = class extends CustomType {
  constructor(replica_id, entries, vclock) {
    super();
    this.replica_id = replica_id;
    this.entries = entries;
    this.vclock = vclock;
  }
};
function new$6(replica_id) {
  return new MVRegister(replica_id, make(), new$2());
}
function set_with_delta(register, val) {
  let new_vclock = increment(
    register.vclock,
    register.replica_id
  );
  let new_counter = get2(new_vclock, register.replica_id);
  let tag = new Tag(register.replica_id, new_counter);
  let new_state = new MVRegister(
    register.replica_id,
    insert(make(), tag, val),
    new_vclock
  );
  return [new_state, new_state];
}
function set(register, val) {
  let $ = set_with_delta(register, val);
  let updated = $[0];
  return updated;
}
function value2(register) {
  return values(register.entries);
}
function merge6(a, b) {
  let surviving_from_a = filter(
    a.entries,
    (tag, _) => {
      return get2(b.vclock, tag.replica_id) < tag.counter || has(
        b.entries,
        tag
      );
    }
  );
  let surviving_from_b = filter(
    b.entries,
    (tag, _) => {
      return get2(a.vclock, tag.replica_id) < tag.counter || has(
        a.entries,
        tag
      );
    }
  );
  let merged_entries = merge(surviving_from_a, surviving_from_b);
  return new MVRegister(
    a.replica_id,
    merged_entries,
    merge2(a.vclock, b.vclock)
  );
}
function to_json6(register) {
  let rid = register.replica_id;
  let entries = register.entries;
  let vclock = register.vclock;
  let entries_json = array2(
    to_list(entries),
    (pair) => {
      let tag_rid;
      let counter;
      let value$1;
      value$1 = pair[1];
      tag_rid = pair[0].replica_id;
      counter = pair[0].counter;
      return object2(
        toList([
          [
            "tag",
            object2(
              toList([
                ["r", string3(to_string3(tag_rid))],
                ["c", int3(counter)]
              ])
            )
          ],
          ["value", string3(value$1)]
        ])
      );
    }
  );
  let vclock_dict = to_dict(vclock);
  return object2(
    toList([
      ["type", string3("mv_register")],
      ["v", int3(1)],
      [
        "state",
        object2(
          toList([
            ["replica_id", string3(to_string3(rid))],
            ["entries", entries_json],
            [
              "vclock",
              dict3(vclock_dict, to_string3, int3)
            ]
          ])
        )
      ]
    ])
  );
}
function from_json5(json_string) {
  let entry_decoder = field(
    "tag",
    field(
      "r",
      string2,
      (r) => {
        return field(
          "c",
          int2,
          (c) => {
            return success(new Tag(new$(r), c));
          }
        );
      }
    ),
    (tag) => {
      return field(
        "value",
        string2,
        (value4) => {
          return success([tag, value4]);
        }
      );
    }
  );
  let state_decoder = field(
    "state",
    field(
      "replica_id",
      string2,
      (rid_str) => {
        return field(
          "entries",
          list2(entry_decoder),
          (entries_list) => {
            return field(
              "vclock",
              dict2(string2, int2),
              (vclock_dict) => {
                let entries = from_list(entries_list);
                let vclock_rid_dict = fold(
                  vclock_dict,
                  make(),
                  (acc, k, v) => {
                    return insert(acc, new$(k), v);
                  }
                );
                let vclock = from_dict(vclock_rid_dict);
                let is_valid = all(
                  entries_list,
                  (pair) => {
                    let rid;
                    let c;
                    rid = pair[0].replica_id;
                    c = pair[0].counter;
                    let is_positive = c > 0;
                    let vclock_counter = get2(vclock, rid);
                    let is_causal = c <= vclock_counter;
                    return is_positive && is_causal;
                  }
                );
                let mvr = new MVRegister(
                  new$(rid_str),
                  entries,
                  vclock
                );
                if (is_valid) {
                  return success(mvr);
                } else {
                  return failure(
                    mvr,
                    "causally consistent entries and positive counters"
                  );
                }
              }
            );
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "mv_register" && version === 1;
    if ($1) {
      return parse(json_string, state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=mv_register and v=1",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/gleam_stdlib/gleam/set.mjs
var Set2 = class extends CustomType {
  constructor(dict4) {
    super();
    this.dict = dict4;
  }
};
var token = void 0;
function new$7() {
  return new Set2(make());
}
function is_empty3(set2) {
  return isEqual(set2, new$7());
}
function insert2(set2, member) {
  return new Set2(insert(set2.dict, member, token));
}
function contains(set2, member) {
  let _pipe = set2.dict;
  let _pipe$1 = get(_pipe, member);
  return is_ok(_pipe$1);
}
function to_list2(set2) {
  return keys(set2.dict);
}
function from_list2(members) {
  let dict4 = fold2(
    members,
    make(),
    (m, k) => {
      return insert(m, k, token);
    }
  );
  return new Set2(dict4);
}
function fold3(set2, initial, reducer) {
  return fold(set2.dict, initial, (a, k, _) => {
    return reducer(a, k);
  });
}
function filter2(set2, predicate) {
  return new Set2(filter(set2.dict, (m, _) => {
    return predicate(m);
  }));
}
function order(first, second) {
  let $ = size(first.dict) > size(second.dict);
  if ($) {
    return [first, second];
  } else {
    return [second, first];
  }
}
function union(first, second) {
  let $ = order(first, second);
  let larger = $[0];
  let smaller = $[1];
  return fold3(smaller, larger, insert2);
}

// build/dev/javascript/lattice_sets/lattice_sets/g_set.mjs
var GSet = class extends CustomType {
  constructor(elements) {
    super();
    this.elements = elements;
  }
};
function new$8() {
  return new GSet(new$7());
}
function merge7(a, b) {
  return new GSet(union(a.elements, b.elements));
}
function to_json7(g_set) {
  return object2(
    toList([
      ["type", string3("g_set")],
      ["v", int3(1)],
      [
        "state",
        object2(
          toList([
            [
              "elements",
              array2(to_list2(g_set.elements), string3)
            ]
          ])
        )
      ]
    ])
  );
}
function from_json6(json_string) {
  let state_decoder = field(
    "state",
    field(
      "elements",
      list2(string2),
      (elements) => {
        return success(new GSet(from_list2(elements)));
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "g_set" && version === 1;
    if ($1) {
      return parse(json_string, state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=g_set and v=1",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/lattice_sets/lattice_sets/or_set.mjs
var Tag2 = class extends CustomType {
  constructor(replica_id, counter) {
    super();
    this.replica_id = replica_id;
    this.counter = counter;
  }
};
var ORSet = class extends CustomType {
  constructor(replica_id, counter, entries, tombstones, pruned) {
    super();
    this.replica_id = replica_id;
    this.counter = counter;
    this.entries = entries;
    this.tombstones = tombstones;
    this.pruned = pruned;
  }
};
function new$9(replica_id) {
  return new ORSet(
    replica_id,
    0,
    make(),
    new$7(),
    new$2()
  );
}
function add_with_delta(orset, element) {
  let new_counter = orset.counter + 1;
  let tag = new Tag2(orset.replica_id, new_counter);
  let existing_tags = unwrap(
    get(orset.entries, element),
    new$7()
  );
  let new_tags = insert2(existing_tags, tag);
  let updated = new ORSet(
    orset.replica_id,
    new_counter,
    insert(orset.entries, element, new_tags),
    orset.tombstones,
    orset.pruned
  );
  let delta = new ORSet(
    orset.replica_id,
    new_counter,
    from_list(toList([[element, from_list2(toList([tag]))]])),
    new$7(),
    new$2()
  );
  return [updated, delta];
}
function remove_with_delta(orset, element) {
  let removed_tags = unwrap(
    get(orset.entries, element),
    new$7()
  );
  let updated = new ORSet(
    orset.replica_id,
    orset.counter,
    delete$(orset.entries, element),
    union(orset.tombstones, removed_tags),
    orset.pruned
  );
  let delta = new ORSet(
    orset.replica_id,
    orset.counter,
    make(),
    removed_tags,
    new$2()
  );
  return [updated, delta];
}
function value3(orset) {
  let _pipe = keys(orset.entries);
  return from_list2(_pipe);
}
function contains2(orset, element) {
  let $ = get(orset.entries, element);
  if ($ instanceof Ok) {
    let tags = $[0];
    return !is_empty3(tags);
  } else {
    return false;
  }
}
function pruned_on_side_without_live_tag(tag, live_tags, pruned) {
  let rid = tag.replica_id;
  let c = tag.counter;
  return get2(pruned, rid) >= c && !contains(
    live_tags,
    tag
  );
}
function is_pruned_zombie(tag, a_tags, a_pruned, b_tags, b_pruned) {
  return pruned_on_side_without_live_tag(tag, a_tags, a_pruned) || pruned_on_side_without_live_tag(
    tag,
    b_tags,
    b_pruned
  );
}
function not_dominated(tag, pruned) {
  let rid = tag.replica_id;
  let c = tag.counter;
  return get2(pruned, rid) < c;
}
function merge8(a, b) {
  let merged_pruned = merge2(a.pruned, b.pruned);
  let _block;
  let _pipe = union(a.tombstones, b.tombstones);
  _block = filter2(
    _pipe,
    (tag) => {
      return not_dominated(tag, merged_pruned);
    }
  );
  let merged_tombstones = _block;
  let merged_counter = max(a.counter, b.counter);
  let a_keys = keys(a.entries);
  let b_keys = keys(b.entries);
  let all_keys = unique(append(a_keys, b_keys));
  let merged_entries = fold2(
    all_keys,
    make(),
    (acc, element) => {
      let a_tags = unwrap(get(a.entries, element), new$7());
      let b_tags = unwrap(get(b.entries, element), new$7());
      let _block$1;
      let _pipe$1 = union(a_tags, b_tags);
      _block$1 = filter2(
        _pipe$1,
        (tag) => {
          return !contains(merged_tombstones, tag) && !is_pruned_zombie(
            tag,
            a_tags,
            a.pruned,
            b_tags,
            b.pruned
          );
        }
      );
      let combined = _block$1;
      let $ = is_empty3(combined);
      if ($) {
        return acc;
      } else {
        return insert(acc, element, combined);
      }
    }
  );
  return new ORSet(
    a.replica_id,
    merged_counter,
    merged_entries,
    merged_tombstones,
    merged_pruned
  );
}
function tags_to_bound(tags) {
  return fold3(
    tags,
    new$2(),
    (vv, tag) => {
      let rid = tag.replica_id;
      let c = tag.counter;
      return set_max(vv, rid, c);
    }
  );
}
function remove_with_bound(orset, element) {
  let removed_tags = unwrap(
    get(orset.entries, element),
    new$7()
  );
  let bound = tags_to_bound(removed_tags);
  let updated = new ORSet(
    orset.replica_id,
    orset.counter,
    delete$(orset.entries, element),
    union(orset.tombstones, removed_tags),
    orset.pruned
  );
  return [updated, bound];
}
function encode_tag(tag) {
  let rid = tag.replica_id;
  let c = tag.counter;
  return object2(
    toList([
      ["r", string3(to_string3(rid))],
      ["c", int3(c)]
    ])
  );
}
function to_json8(orset) {
  return object2(
    toList([
      ["type", string3("or_set")],
      ["v", int3(2)],
      [
        "state",
        object2(
          toList([
            ["replica_id", to_json(orset.replica_id)],
            ["counter", int3(orset.counter)],
            [
              "entries",
              dict3(
                orset.entries,
                (k) => {
                  return k;
                },
                (tag_set) => {
                  return array2(to_list2(tag_set), encode_tag);
                }
              )
            ],
            [
              "tombstones",
              array2(to_list2(orset.tombstones), encode_tag)
            ],
            ["pruned", to_json2(orset.pruned)]
          ])
        )
      ]
    ])
  );
}
function from_json7(json_string) {
  let tag_decoder = field(
    "r",
    decoder(),
    (r) => {
      return field(
        "c",
        int2,
        (c) => {
          return success(new Tag2(r, c));
        }
      );
    }
  );
  let tag_set_decoder = map3(list2(tag_decoder), from_list2);
  let v1_state_decoder = field(
    "state",
    field(
      "replica_id",
      decoder(),
      (replica_id) => {
        return field(
          "counter",
          int2,
          (counter) => {
            return field(
              "entries",
              dict2(string2, tag_set_decoder),
              (entries) => {
                return optional_field(
                  "tombstones",
                  List$Empty$const,
                  list2(tag_decoder),
                  (tombstones) => {
                    return success(
                      new ORSet(
                        replica_id,
                        counter,
                        entries,
                        from_list2(tombstones),
                        new$2()
                      )
                    );
                  }
                );
              }
            );
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let v2_state_decoder = field(
    "state",
    field(
      "replica_id",
      decoder(),
      (replica_id) => {
        return field(
          "counter",
          int2,
          (counter) => {
            return field(
              "entries",
              dict2(string2, tag_set_decoder),
              (entries) => {
                return field(
                  "tombstones",
                  tag_set_decoder,
                  (tombstones) => {
                    return field(
                      "pruned",
                      decoder2(),
                      (pruned) => {
                        return success(
                          new ORSet(
                            replica_id,
                            counter,
                            entries,
                            tombstones,
                            pruned
                          )
                        );
                      }
                    );
                  }
                );
              }
            );
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "or_set";
    if ($1) {
      if (version === 1) {
        return parse(json_string, v1_state_decoder);
      } else if (version === 2) {
        return parse(json_string, v2_state_decoder);
      } else {
        return new Error(
          new UnableToDecode(
            toList([
              new DecodeError(
                "v=1 or v=2",
                to_string(version),
                toList(["v"])
              )
            ])
          )
        );
      }
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError("type=or_set", type_tag, List$Empty$const)
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/lattice_sets/lattice_sets/two_p_set.mjs
var TwoPSet = class extends CustomType {
  constructor(added, removed) {
    super();
    this.added = added;
    this.removed = removed;
  }
};
function new$10() {
  return new TwoPSet(new$7(), new$7());
}
function merge9(a, b) {
  return new TwoPSet(
    union(a.added, b.added),
    union(a.removed, b.removed)
  );
}
function to_json9(tpset) {
  return object2(
    toList([
      ["type", string3("two_p_set")],
      ["v", int3(1)],
      [
        "state",
        object2(
          toList([
            ["added", array2(to_list2(tpset.added), string3)],
            ["removed", array2(to_list2(tpset.removed), string3)]
          ])
        )
      ]
    ])
  );
}
function from_json8(json_string) {
  let state_decoder = field(
    "state",
    field(
      "added",
      list2(string2),
      (added) => {
        return field(
          "removed",
          list2(string2),
          (removed) => {
            return success(
              new TwoPSet(from_list2(added), from_list2(removed))
            );
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "two_p_set" && version === 1;
    if ($1) {
      return parse(json_string, state_decoder);
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError(
              "type=two_p_set and v=1",
              type_tag + " v=" + to_string(version),
              List$Empty$const
            )
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/lattice_maps/lattice_maps/crdt.mjs
var CrdtGCounter = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtPnCounter = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtLwwRegister = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtMvRegister = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtGSet = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtTwoPSet = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtOrSet = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var CrdtVersionVector = class extends CustomType {
  constructor($0) {
    super();
    this[0] = $0;
  }
};
var TypeMismatch = class extends CustomType {
  constructor(expected, found) {
    super();
    this.expected = expected;
    this.found = found;
  }
};
var GCounterSpec = class extends CustomType {
};
var CrdtSpec$GCounterSpec$const = new GCounterSpec();
var PnCounterSpec = class extends CustomType {
};
var CrdtSpec$PnCounterSpec$const = new PnCounterSpec();
var LwwRegisterSpec = class extends CustomType {
};
var CrdtSpec$LwwRegisterSpec$const = new LwwRegisterSpec();
var MvRegisterSpec = class extends CustomType {
};
var CrdtSpec$MvRegisterSpec$const = new MvRegisterSpec();
var GSetSpec = class extends CustomType {
};
var CrdtSpec$GSetSpec$const = new GSetSpec();
var TwoPSetSpec = class extends CustomType {
};
var CrdtSpec$TwoPSetSpec$const = new TwoPSetSpec();
var OrSetSpec = class extends CustomType {
};
var CrdtSpec$OrSetSpec$const = new OrSetSpec();
function type_name(value4) {
  if (value4 instanceof CrdtGCounter) {
    return "g_counter";
  } else if (value4 instanceof CrdtPnCounter) {
    return "pn_counter";
  } else if (value4 instanceof CrdtLwwRegister) {
    return "lww_register";
  } else if (value4 instanceof CrdtMvRegister) {
    return "mv_register";
  } else if (value4 instanceof CrdtGSet) {
    return "g_set";
  } else if (value4 instanceof CrdtTwoPSet) {
    return "two_p_set";
  } else if (value4 instanceof CrdtOrSet) {
    return "or_set";
  } else {
    return "version_vector";
  }
}
function default_crdt(spec, replica_id) {
  if (spec instanceof GCounterSpec) {
    return new CrdtGCounter(new$3(replica_id));
  } else if (spec instanceof PnCounterSpec) {
    return new CrdtPnCounter(new$4(replica_id));
  } else if (spec instanceof LwwRegisterSpec) {
    return new CrdtLwwRegister(new$5("", 0, replica_id));
  } else if (spec instanceof MvRegisterSpec) {
    return new CrdtMvRegister(new$6(replica_id));
  } else if (spec instanceof GSetSpec) {
    return new CrdtGSet(new$8());
  } else if (spec instanceof TwoPSetSpec) {
    return new CrdtTwoPSet(new$10());
  } else {
    return new CrdtOrSet(new$9(replica_id));
  }
}
function matches_spec(value4, spec) {
  if (spec instanceof GCounterSpec) {
    if (value4 instanceof CrdtGCounter) {
      return true;
    } else {
      return false;
    }
  } else if (spec instanceof PnCounterSpec) {
    if (value4 instanceof CrdtPnCounter) {
      return true;
    } else {
      return false;
    }
  } else if (spec instanceof LwwRegisterSpec) {
    if (value4 instanceof CrdtLwwRegister) {
      return true;
    } else {
      return false;
    }
  } else if (spec instanceof MvRegisterSpec) {
    if (value4 instanceof CrdtMvRegister) {
      return true;
    } else {
      return false;
    }
  } else if (spec instanceof GSetSpec) {
    if (value4 instanceof CrdtGSet) {
      return true;
    } else {
      return false;
    }
  } else if (spec instanceof TwoPSetSpec) {
    if (value4 instanceof CrdtTwoPSet) {
      return true;
    } else {
      return false;
    }
  } else if (value4 instanceof CrdtOrSet) {
    return true;
  } else {
    return false;
  }
}
function merge10(a, b) {
  if (a instanceof CrdtGCounter) {
    if (b instanceof CrdtGCounter) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtGCounter(merge3(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (a instanceof CrdtPnCounter) {
    if (b instanceof CrdtPnCounter) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtPnCounter(merge4(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (a instanceof CrdtLwwRegister) {
    if (b instanceof CrdtLwwRegister) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtLwwRegister(merge5(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (a instanceof CrdtMvRegister) {
    if (b instanceof CrdtMvRegister) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtMvRegister(merge6(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (a instanceof CrdtGSet) {
    if (b instanceof CrdtGSet) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtGSet(merge7(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (a instanceof CrdtTwoPSet) {
    if (b instanceof CrdtTwoPSet) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtTwoPSet(merge9(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (a instanceof CrdtOrSet) {
    if (b instanceof CrdtOrSet) {
      let ca = a[0];
      let cb = b[0];
      return new Ok(new CrdtOrSet(merge8(ca, cb)));
    } else {
      return new Error(new TypeMismatch(type_name(a), type_name(b)));
    }
  } else if (b instanceof CrdtVersionVector) {
    let ca = a[0];
    let cb = b[0];
    return new Ok(new CrdtVersionVector(merge2(ca, cb)));
  } else {
    return new Error(new TypeMismatch(type_name(a), type_name(b)));
  }
}
function to_json10(crdt) {
  if (crdt instanceof CrdtGCounter) {
    let c = crdt[0];
    return to_json3(c);
  } else if (crdt instanceof CrdtPnCounter) {
    let c = crdt[0];
    return to_json4(c);
  } else if (crdt instanceof CrdtLwwRegister) {
    let c = crdt[0];
    return to_json5(c);
  } else if (crdt instanceof CrdtMvRegister) {
    let c = crdt[0];
    return to_json6(c);
  } else if (crdt instanceof CrdtGSet) {
    let c = crdt[0];
    return to_json7(c);
  } else if (crdt instanceof CrdtTwoPSet) {
    let c = crdt[0];
    return to_json9(c);
  } else if (crdt instanceof CrdtOrSet) {
    let c = crdt[0];
    return to_json8(c);
  } else {
    let c = crdt[0];
    return to_json2(c);
  }
}
function dispatch_decode(type_tag, json_string) {
  if (type_tag === "g_counter") {
    let $ = from_json2(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtGCounter(c));
    } else {
      return $;
    }
  } else if (type_tag === "pn_counter") {
    let $ = from_json3(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtPnCounter(c));
    } else {
      return $;
    }
  } else if (type_tag === "lww_register") {
    let $ = from_json4(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtLwwRegister(c));
    } else {
      return $;
    }
  } else if (type_tag === "mv_register") {
    let $ = from_json5(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtMvRegister(c));
    } else {
      return $;
    }
  } else if (type_tag === "g_set") {
    let $ = from_json6(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtGSet(c));
    } else {
      return $;
    }
  } else if (type_tag === "two_p_set") {
    let $ = from_json8(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtTwoPSet(c));
    } else {
      return $;
    }
  } else if (type_tag === "or_set") {
    let $ = from_json7(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtOrSet(c));
    } else {
      return $;
    }
  } else if (type_tag === "version_vector") {
    let $ = from_json(json_string);
    if ($ instanceof Ok) {
      let c = $[0];
      return new Ok(new CrdtVersionVector(c));
    } else {
      return $;
    }
  } else {
    return new Error(
      new UnableToDecode(
        toList([
          new DecodeError("known CRDT type", type_tag, toList(["type"]))
        ])
      )
    );
  }
}
function from_json9(json_string) {
  let type_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return success(type_tag);
    }
  );
  let $ = parse(json_string, type_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0];
    return dispatch_decode(type_tag, json_string);
  } else {
    return $;
  }
}

// build/dev/javascript/lattice_maps/lattice_maps/or_map.mjs
var ORMap = class extends CustomType {
  constructor(replica_id, crdt_spec, key_set, values2, remove_bounds) {
    super();
    this.replica_id = replica_id;
    this.crdt_spec = crdt_spec;
    this.key_set = key_set;
    this.values = values2;
    this.remove_bounds = remove_bounds;
  }
};
var ORMapDelta = class extends CustomType {
  constructor(replica_id, crdt_spec, key_set_delta, value_deltas, remove_bounds_delta) {
    super();
    this.replica_id = replica_id;
    this.crdt_spec = crdt_spec;
    this.key_set_delta = key_set_delta;
    this.value_deltas = value_deltas;
    this.remove_bounds_delta = remove_bounds_delta;
  }
};
function spec_to_string(spec) {
  if (spec instanceof GCounterSpec) {
    return "g_counter";
  } else if (spec instanceof PnCounterSpec) {
    return "pn_counter";
  } else if (spec instanceof LwwRegisterSpec) {
    return "lww_register";
  } else if (spec instanceof MvRegisterSpec) {
    return "mv_register";
  } else if (spec instanceof GSetSpec) {
    return "g_set";
  } else if (spec instanceof TwoPSetSpec) {
    return "two_p_set";
  } else {
    return "or_set";
  }
}
function string_to_spec(s) {
  if (s === "g_counter") {
    return new Ok(CrdtSpec$GCounterSpec$const);
  } else if (s === "pn_counter") {
    return new Ok(CrdtSpec$PnCounterSpec$const);
  } else if (s === "lww_register") {
    return new Ok(CrdtSpec$LwwRegisterSpec$const);
  } else if (s === "mv_register") {
    return new Ok(CrdtSpec$MvRegisterSpec$const);
  } else if (s === "g_set") {
    return new Ok(CrdtSpec$GSetSpec$const);
  } else if (s === "two_p_set") {
    return new Ok(CrdtSpec$TwoPSetSpec$const);
  } else if (s === "or_set") {
    return new Ok(CrdtSpec$OrSetSpec$const);
  } else {
    return new Error(void 0);
  }
}
function new$11(replica_id, crdt_spec) {
  return new ORMap(
    replica_id,
    crdt_spec,
    new$9(replica_id),
    make(),
    make()
  );
}
function put_value(map4, key, value4) {
  let $ = add_with_delta(map4.key_set, key);
  let updated_key_set = $[0];
  let key_set_delta = $[1];
  return [
    new ORMap(
      map4.replica_id,
      map4.crdt_spec,
      updated_key_set,
      insert(map4.values, key, value4),
      delete$(map4.remove_bounds, key)
    ),
    key_set_delta
  ];
}
function current_value(map4, key) {
  let $ = contains2(map4.key_set, key);
  let $1 = get(map4.values, key);
  if ($ && $1 instanceof Ok) {
    let crdt_val = $1[0];
    return crdt_val;
  } else {
    return default_crdt(map4.crdt_spec, map4.replica_id);
  }
}
function update(map4, key, f) {
  let current = current_value(map4, key);
  let new_value = f(current);
  let _block;
  let $ = matches_spec(new_value, map4.crdt_spec);
  if ($) {
    _block = new_value;
  } else {
    _block = current;
  }
  let safe_value = _block;
  let $1 = put_value(map4, key, safe_value);
  let updated = $1[0];
  return updated;
}
function get3(map4, key) {
  return guard(
    !contains2(map4.key_set, key),
    new Error(void 0),
    () => {
      return get(map4.values, key);
    }
  );
}
function remove_with_delta2(map4, key) {
  let $ = remove_with_delta(map4.key_set, key);
  let updated_key_set = $[0];
  let key_set_delta = $[1];
  let $1 = remove_with_bound(map4.key_set, key);
  let bound = $1[1];
  let _block;
  let $3 = is_empty2(bound);
  if ($3) {
    _block = [map4.remove_bounds, make()];
  } else {
    _block = [
      insert(map4.remove_bounds, key, bound),
      from_list(toList([[key, bound]]))
    ];
  }
  let $2 = _block;
  let updated_bounds = $2[0];
  let bounds_delta = $2[1];
  let updated = new ORMap(
    map4.replica_id,
    map4.crdt_spec,
    updated_key_set,
    map4.values,
    updated_bounds
  );
  let delta = new ORMapDelta(
    map4.replica_id,
    map4.crdt_spec,
    key_set_delta,
    make(),
    bounds_delta
  );
  return [updated, delta];
}
function remove(map4, key) {
  let $ = remove_with_delta2(map4, key);
  let updated = $[0];
  return updated;
}
function keys2(map4) {
  return to_list2(value3(map4.key_set));
}
function validated(map4, value4) {
  return guard(
    matches_spec(value4, map4.crdt_spec),
    value4,
    () => {
      return default_crdt(map4.crdt_spec, map4.replica_id);
    }
  );
}
function valid_value(map4, key) {
  let $ = get(map4.values, key);
  if ($ instanceof Ok) {
    let value4 = $[0];
    return new Ok(validated(map4, value4));
  } else {
    return new Error(void 0);
  }
}
function merge11(a, b) {
  return guard(
    !isEqual(a.crdt_spec, b.crdt_spec),
    new Error(
      new TypeMismatch(
        spec_to_string(a.crdt_spec),
        spec_to_string(b.crdt_spec)
      )
    ),
    () => {
      let merged_key_set = merge8(a.key_set, b.key_set);
      let active_keys = value3(merged_key_set);
      let values_from_a = fold(
        a.values,
        make(),
        (acc, key, value_a) => {
          let value_a$1 = validated(a, value_a);
          let _block;
          let $ = valid_value(b, key);
          if ($ instanceof Ok) {
            let value_b = $[0];
            let $1 = merge10(value_a$1, value_b);
            if ($1 instanceof Ok) {
              let merged = $1[0];
              _block = merged;
            } else {
              _block = default_crdt(a.crdt_spec, a.replica_id);
            }
          } else {
            _block = value_a$1;
          }
          let merged_crdt = _block;
          return insert(acc, key, merged_crdt);
        }
      );
      let merged_values = fold(
        b.values,
        values_from_a,
        (acc, key, value_b) => {
          let $ = has(a.values, key);
          if ($) {
            return acc;
          } else {
            return insert(acc, key, validated(b, value_b));
          }
        }
      );
      let all_bound_keys = to_list2(
        union(
          from_list2(keys(a.remove_bounds)),
          from_list2(keys(b.remove_bounds))
        )
      );
      let merged_bounds = fold2(
        all_bound_keys,
        make(),
        (acc, key) => {
          let $ = contains(active_keys, key);
          if ($) {
            return acc;
          } else {
            let $1 = get(a.remove_bounds, key);
            let $2 = get(b.remove_bounds, key);
            if ($1 instanceof Ok) {
              if ($2 instanceof Ok) {
                let ba = $1[0];
                let bb = $2[0];
                return insert(acc, key, merge2(ba, bb));
              } else {
                let ba = $1[0];
                return insert(acc, key, ba);
              }
            } else if ($2 instanceof Ok) {
              let bb = $2[0];
              return insert(acc, key, bb);
            } else {
              return acc;
            }
          }
        }
      );
      return new Ok(
        new ORMap(
          a.replica_id,
          a.crdt_spec,
          merged_key_set,
          merged_values,
          merged_bounds
        )
      );
    }
  );
}
function to_json11(map4) {
  let rid = map4.replica_id;
  let crdt_spec = map4.crdt_spec;
  let key_set = map4.key_set;
  let values$1 = map4.values;
  let remove_bounds = map4.remove_bounds;
  let values_json = array2(
    to_list(values$1),
    (pair) => {
      let key = pair[0];
      let crdt_val = pair[1];
      return object2(
        toList([
          ["key", string3(key)],
          ["crdt", string3(to_string2(to_json10(crdt_val)))]
        ])
      );
    }
  );
  let bounds_json = dict3(
    remove_bounds,
    (k) => {
      return k;
    },
    (vv) => {
      return to_json2(vv);
    }
  );
  return object2(
    toList([
      ["type", string3("or_map")],
      ["v", int3(2)],
      [
        "state",
        object2(
          toList([
            ["replica_id", string3(to_string3(rid))],
            ["crdt_spec", string3(spec_to_string(crdt_spec))],
            ["key_set", string3(to_string2(to_json8(key_set)))],
            ["values", values_json],
            ["remove_bounds", bounds_json]
          ])
        )
      ]
    ])
  );
}
function decode_or_map_state(replica_id_str, crdt_spec_str, key_set_str, values_list, remove_bounds) {
  return try$(
    replace_error(
      string_to_spec(crdt_spec_str),
      new UnableToDecode(
        toList([
          new DecodeError(
            "known CrdtSpec",
            crdt_spec_str,
            toList(["state", "crdt_spec"])
          )
        ])
      )
    ),
    (crdt_spec) => {
      return try$(
        from_json7(key_set_str),
        (key_set) => {
          return try$(
            try_map(
              values_list,
              (pair) => {
                let key = pair[0];
                let crdt_str = pair[1];
                return try$(
                  from_json9(crdt_str),
                  (c) => {
                    return guard(
                      !matches_spec(c, crdt_spec),
                      new Error(
                        new UnableToDecode(
                          toList([
                            new DecodeError(
                              spec_to_string(crdt_spec),
                              type_name(c),
                              toList(["state", "values"])
                            )
                          ])
                        )
                      ),
                      () => {
                        return new Ok([key, c]);
                      }
                    );
                  }
                );
              }
            ),
            (pairs) => {
              return new Ok(
                new ORMap(
                  new$(replica_id_str),
                  crdt_spec,
                  key_set,
                  from_list(pairs),
                  remove_bounds
                )
              );
            }
          );
        }
      );
    }
  );
}
function from_json10(json_string) {
  let value_pair_decoder = field(
    "key",
    string2,
    (key) => {
      return field(
        "crdt",
        string2,
        (crdt_str) => {
          return success([key, crdt_str]);
        }
      );
    }
  );
  let bounds_decoder = dict2(string2, decoder2());
  let state_decoder = field(
    "state",
    field(
      "replica_id",
      string2,
      (replica_id_str) => {
        return field(
          "crdt_spec",
          string2,
          (crdt_spec_str) => {
            return field(
              "key_set",
              string2,
              (key_set_str) => {
                return field(
                  "values",
                  list2(value_pair_decoder),
                  (values_list) => {
                    return optional_field(
                      "remove_bounds",
                      make(),
                      bounds_decoder,
                      (remove_bounds) => {
                        return success(
                          [
                            replica_id_str,
                            crdt_spec_str,
                            key_set_str,
                            values_list,
                            remove_bounds
                          ]
                        );
                      }
                    );
                  }
                );
              }
            );
          }
        );
      }
    ),
    (state) => {
      return success(state);
    }
  );
  let envelope_decoder = field(
    "type",
    string2,
    (type_tag) => {
      return field(
        "v",
        int2,
        (version) => {
          return success([type_tag, version]);
        }
      );
    }
  );
  let $ = parse(json_string, envelope_decoder);
  if ($ instanceof Ok) {
    let type_tag = $[0][0];
    let version = $[0][1];
    let $1 = type_tag === "or_map";
    if ($1) {
      if (version === 1) {
        let $2 = parse(json_string, state_decoder);
        if ($2 instanceof Ok) {
          let replica_id_str = $2[0][0];
          let crdt_spec_str = $2[0][1];
          let key_set_str = $2[0][2];
          let values_list = $2[0][3];
          let remove_bounds = $2[0][4];
          return decode_or_map_state(
            replica_id_str,
            crdt_spec_str,
            key_set_str,
            values_list,
            remove_bounds
          );
        } else {
          return $2;
        }
      } else if (version === 2) {
        let $2 = parse(json_string, state_decoder);
        if ($2 instanceof Ok) {
          let replica_id_str = $2[0][0];
          let crdt_spec_str = $2[0][1];
          let key_set_str = $2[0][2];
          let values_list = $2[0][3];
          let remove_bounds = $2[0][4];
          return decode_or_map_state(
            replica_id_str,
            crdt_spec_str,
            key_set_str,
            values_list,
            remove_bounds
          );
        } else {
          return $2;
        }
      } else {
        return new Error(
          new UnableToDecode(
            toList([
              new DecodeError(
                "v=1 or v=2",
                to_string(version),
                toList(["v"])
              )
            ])
          )
        );
      }
    } else {
      return new Error(
        new UnableToDecode(
          toList([
            new DecodeError("type=or_map", type_tag, List$Empty$const)
          ])
        )
      );
    }
  } else {
    return $;
  }
}

// build/dev/javascript/collab_docs_client/collab_docs_client.mjs
var Document = class extends CustomType {
  constructor(replica, state) {
    super();
    this.replica = replica;
    this.state = state;
  }
};
var RenderBlock = class extends CustomType {
  constructor(id, values2) {
    super();
    this.id = id;
    this.values = values2;
  }
};
var RenderBlock$RenderBlock = (id, values2) => new RenderBlock(id, values2);
var RenderBlock$isRenderBlock = (value4) => value4 instanceof RenderBlock;
var RenderBlock$RenderBlock$id = (value4) => value4.id;
var RenderBlock$RenderBlock$0 = (value4) => value4.id;
var RenderBlock$RenderBlock$values = (value4) => value4.values;
var RenderBlock$RenderBlock$1 = (value4) => value4.values;
var InvalidState = class extends CustomType {
  constructor(reason) {
    super();
    this.reason = reason;
  }
};
var DocumentError$InvalidState = (reason) => new InvalidState(reason);
var DocumentError$isInvalidState = (value4) => value4 instanceof InvalidState;
var DocumentError$InvalidState$reason = (value4) => value4.reason;
var DocumentError$InvalidState$0 = (value4) => value4.reason;
var MergeFailed = class extends CustomType {
  constructor(reason) {
    super();
    this.reason = reason;
  }
};
var DocumentError$MergeFailed = (reason) => new MergeFailed(reason);
var DocumentError$isMergeFailed = (value4) => value4 instanceof MergeFailed;
var DocumentError$MergeFailed$reason = (value4) => value4.reason;
var DocumentError$MergeFailed$0 = (value4) => value4.reason;
var InvalidBlock = class extends CustomType {
  constructor(reason) {
    super();
    this.reason = reason;
  }
};
var DocumentError$InvalidBlock = (reason) => new InvalidBlock(reason);
var DocumentError$isInvalidBlock = (value4) => value4 instanceof InvalidBlock;
var DocumentError$InvalidBlock$reason = (value4) => value4.reason;
var DocumentError$InvalidBlock$0 = (value4) => value4.reason;
var EmptyBlockId = class extends CustomType {
};
var DocumentError$EmptyBlockId$const = new EmptyBlockId();
var DocumentError$EmptyBlockId = () => DocumentError$EmptyBlockId$const;
var DocumentError$isEmptyBlockId = (value4) => value4 instanceof EmptyBlockId;
var BlockIdMismatch = class extends CustomType {
  constructor(expected, actual) {
    super();
    this.expected = expected;
    this.actual = actual;
  }
};
var DocumentError$BlockIdMismatch = (expected, actual) => new BlockIdMismatch(expected, actual);
var DocumentError$isBlockIdMismatch = (value4) => value4 instanceof BlockIdMismatch;
var DocumentError$BlockIdMismatch$expected = (value4) => value4.expected;
var DocumentError$BlockIdMismatch$0 = (value4) => value4.expected;
var DocumentError$BlockIdMismatch$actual = (value4) => value4.actual;
var DocumentError$BlockIdMismatch$1 = (value4) => value4.actual;
function new_document(replica) {
  return new Document(
    replica,
    new$11(new$(replica), CrdtSpec$MvRegisterSpec$const)
  );
}
function json_to_document(replica, encoded) {
  let $ = from_json10(encoded);
  if ($ instanceof Ok) {
    let remote = $[0];
    let $1 = new_document(replica);
    let local = $1.state;
    let $2 = merge11(local, remote);
    if ($2 instanceof Ok) {
      let state = $2[0];
      return new Ok(new Document(replica, state));
    } else {
      let reason = $2[0];
      return new Error(new MergeFailed(reason));
    }
  } else {
    let reason = $[0];
    return new Error(new InvalidState(reason));
  }
}
function document_to_json(document) {
  let state = document.state;
  let _pipe = state;
  let _pipe$1 = to_json11(_pipe);
  return to_string2(_pipe$1);
}
function put_block(document, id, block_json) {
  let replica = document.replica;
  let state = document.state;
  let replica_id = new$(replica);
  let updated = update(
    state,
    id,
    (value4) => {
      if (value4 instanceof CrdtGCounter) {
        return value4;
      } else if (value4 instanceof CrdtPnCounter) {
        return value4;
      } else if (value4 instanceof CrdtLwwRegister) {
        return value4;
      } else if (value4 instanceof CrdtMvRegister) {
        let register = value4[0];
        let _block;
        let _pipe = new$6(replica_id);
        _block = merge6(_pipe, register);
        let local_register = _block;
        return new CrdtMvRegister(
          set(local_register, block_json)
        );
      } else if (value4 instanceof CrdtGSet) {
        return value4;
      } else if (value4 instanceof CrdtTwoPSet) {
        return value4;
      } else if (value4 instanceof CrdtOrSet) {
        return value4;
      } else {
        return value4;
      }
    }
  );
  return new Document(replica, updated);
}
function extract_block_id(block_json) {
  let $ = parse(block_json, at(toList(["id"]), string2));
  if ($ instanceof Ok) {
    let $1 = $[0];
    if ($1 === "") {
      return new Error(DocumentError$EmptyBlockId$const);
    } else {
      return $;
    }
  } else {
    let reason = $[0];
    return new Error(new InvalidBlock(reason));
  }
}
function add_block(document, block_json) {
  return try$(
    extract_block_id(block_json),
    (id) => {
      return new Ok(put_block(document, id, block_json));
    }
  );
}
function edit_block(document, expected_id, block_json) {
  let $ = extract_block_id(block_json);
  if ($ instanceof Ok) {
    let actual_id = $[0];
    if (actual_id === expected_id) {
      return new Ok(put_block(document, expected_id, block_json));
    } else {
      let actual_id2 = $[0];
      return new Error(new BlockIdMismatch(expected_id, actual_id2));
    }
  } else {
    return $;
  }
}
function remove_block(document, block_id) {
  let replica = document.replica;
  let state = document.state;
  return new Document(replica, remove(state, block_id));
}
function merge_json(document, remote_json) {
  let replica = document.replica;
  let state = document.state;
  let $ = from_json10(remote_json);
  if ($ instanceof Ok) {
    let remote = $[0];
    let $1 = merge11(state, remote);
    if ($1 instanceof Ok) {
      let merged = $1[0];
      return new Ok(new Document(replica, merged));
    } else {
      let reason = $1[0];
      return new Error(new MergeFailed(reason));
    }
  } else {
    let reason = $[0];
    return new Error(new InvalidState(reason));
  }
}
function blocks(document) {
  let state = document.state;
  let _pipe = state;
  let _pipe$1 = keys2(_pipe);
  let _pipe$2 = sort(_pipe$1, compare2);
  return map2(
    _pipe$2,
    (id) => {
      let _block;
      let $ = get3(state, id);
      if ($ instanceof Ok) {
        let $1 = $[0];
        if ($1 instanceof CrdtGCounter) {
          _block = List$Empty$const;
        } else if ($1 instanceof CrdtPnCounter) {
          _block = List$Empty$const;
        } else if ($1 instanceof CrdtLwwRegister) {
          _block = List$Empty$const;
        } else if ($1 instanceof CrdtMvRegister) {
          let register = $1[0];
          let _pipe$3 = register;
          let _pipe$4 = value2(_pipe$3);
          _block = sort(_pipe$4, compare2);
        } else if ($1 instanceof CrdtGSet) {
          _block = List$Empty$const;
        } else if ($1 instanceof CrdtTwoPSet) {
          _block = List$Empty$const;
        } else if ($1 instanceof CrdtOrSet) {
          _block = List$Empty$const;
        } else {
          _block = List$Empty$const;
        }
      } else {
        _block = List$Empty$const;
      }
      let values2 = _block;
      return new RenderBlock(id, values2);
    }
  );
}
function blocks_json(document) {
  let _pipe = document;
  let _pipe$1 = blocks(_pipe);
  let _pipe$2 = array2(
    _pipe$1,
    (block) => {
      return object2(
        toList([
          ["id", string3(block.id)],
          ["values", array2(block.values, string3)]
        ])
      );
    }
  );
  return to_string2(_pipe$2);
}
function merge_json_or_keep(document, remote_json) {
  let $ = merge_json(document, remote_json);
  if ($ instanceof Ok) {
    let merged = $[0];
    return merged;
  } else {
    return document;
  }
}
function document_error_to_string(error) {
  if (error instanceof InvalidState) {
    return "invalid_state";
  } else if (error instanceof MergeFailed) {
    return "merge_failed";
  } else if (error instanceof InvalidBlock) {
    return "invalid_block";
  } else if (error instanceof EmptyBlockId) {
    return "empty_block_id";
  } else {
    return "block_id_mismatch";
  }
}
export {
  BlockIdMismatch,
  DocumentError$BlockIdMismatch,
  DocumentError$BlockIdMismatch$0,
  DocumentError$BlockIdMismatch$1,
  DocumentError$BlockIdMismatch$actual,
  DocumentError$BlockIdMismatch$expected,
  DocumentError$EmptyBlockId,
  DocumentError$EmptyBlockId$const,
  DocumentError$InvalidBlock,
  DocumentError$InvalidBlock$0,
  DocumentError$InvalidBlock$reason,
  DocumentError$InvalidState,
  DocumentError$InvalidState$0,
  DocumentError$InvalidState$reason,
  DocumentError$MergeFailed,
  DocumentError$MergeFailed$0,
  DocumentError$MergeFailed$reason,
  DocumentError$isBlockIdMismatch,
  DocumentError$isEmptyBlockId,
  DocumentError$isInvalidBlock,
  DocumentError$isInvalidState,
  DocumentError$isMergeFailed,
  EmptyBlockId,
  InvalidBlock,
  InvalidState,
  MergeFailed,
  RenderBlock,
  RenderBlock$RenderBlock,
  RenderBlock$RenderBlock$0,
  RenderBlock$RenderBlock$1,
  RenderBlock$RenderBlock$id,
  RenderBlock$RenderBlock$values,
  RenderBlock$isRenderBlock,
  add_block,
  blocks,
  blocks_json,
  document_error_to_string,
  document_to_json,
  edit_block,
  json_to_document,
  merge_json,
  merge_json_or_keep,
  new_document,
  remove_block
};
