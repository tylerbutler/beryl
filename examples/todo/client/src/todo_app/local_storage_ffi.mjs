export function getItem(key) {
  try {
    const value = window.localStorage.getItem(key);
    return { ok: true, found: value !== null, value: value ?? "" };
  } catch {
    return { ok: false, found: false, value: "" };
  }
}

export function setItem(key, value) {
  try {
    window.localStorage.setItem(key, value);
    return true;
  } catch {
    return false;
  }
}
