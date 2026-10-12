import { describe, expect, it } from 'vitest'
import { duration, modeColor, modeLabel } from './modes'

describe('duration', () => {
  it.each([[150, '2 Std. 30 Min.'], [45, '45 Min.'], [480, '8 Std.'], [60, '1 Std.'], [0, ''], [-5, '']])('%s minutes is "%s"', (minutes, text) => expect(duration(minutes)).toBe(text))
})

describe('modes', () => {
  it('knows labels and colours, and falls back for an unknown mode', () => {
    expect(modeLabel('shinkansen')).toBe('Shinkansen')
    expect(modeColor('bus')).toMatch(/^#/)
    expect(modeLabel('raumschiff')).toBe('raumschiff')
    expect(modeColor('raumschiff')).toBe('#757575')
  })
})
