/** Visit length to ask slots for: the chosen type's, else the longest offered type's; undefined without types. */
export function slotLengthFor(types: { id: string; effectiveDurationMinutes: number }[], chosenId: string | null): number | undefined {
  const chosen = chosenId ? types.find((t) => t.id === chosenId) : undefined
  if (chosen) return chosen.effectiveDurationMinutes
  return types.length ? Math.max(...types.map((t) => t.effectiveDurationMinutes)) : undefined
}
