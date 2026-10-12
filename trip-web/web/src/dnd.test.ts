import { describe, expect, it } from 'vitest'
import { finalIndex } from './dnd'

describe('finalIndex', () => {
  it('counts the dragged item itself when it moves down in the same list', () => {
    expect(finalIndex('a', 0, 'a', 2)).toBe(1)     // [x, y, z]: x dropped before z ends up second
    expect(finalIndex('a', 0, 'a', 3)).toBe(2)     // at the end
  })
  it('keeps the position when it moves up or stays', () => {
    expect(finalIndex('a', 2, 'a', 0)).toBe(0)
    expect(finalIndex('a', 1, 'a', 1)).toBe(1)
    expect(finalIndex('a', 1, 'a', 2)).toBe(1)     // dropped right behind itself: no change
  })
  it('uses the drop position as it is for another list', () => {
    expect(finalIndex('a', 0, 'b', 2)).toBe(2)
  })
})
