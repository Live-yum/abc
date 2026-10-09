/** Runtime helpers for Mini Program JavaScript engines. Syntax transforms cannot
 * provide newer Object methods, so keep these local instead of changing globals.
 */
export function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key)
}

export function fromEntries(entries) {
  const result = {}
  for (const [key, value] of entries) {
    // Assignment to __proto__ would change the prototype instead of adding data.
    Object.defineProperty(result, key, { value, enumerable: true, writable: true, configurable: true })
  }
  return result
}
