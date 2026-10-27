// Stable test ids (standing rule, 27 Oct 2026): every form field carries a data-testid named
// module-screen-element in kebab-case, e.g. `scheduling-booking-visit-type`.
// Fields inside shared components that spread props (`{...props}`) are exempt: the caller sets the id.
export const FIELD_TAGS = ['FormField', 'SelectField', 'TimeZoneField', 'Textarea', 'input', 'select', 'textarea']

export const FIELD_WITHOUT_TESTID =
  `JSXOpeningElement[name.name=/^(${FIELD_TAGS.join('|')})$/]` +
  ":not(:has(JSXAttribute[name.name='data-testid'])):not(:has(JSXSpreadAttribute))"

export const NON_KEBAB_TESTID = "JSXAttribute[name.name='data-testid'] > Literal:not([value=/^[a-z0-9]+(-[a-z0-9]+)*$/])"

export const testIdRules = [
  {
    selector: FIELD_WITHOUT_TESTID,
    message: 'Form fields need a data-testid named module-screen-element, e.g. data-testid="billing-drawer-refund-rupees".',
  },
  { selector: NON_KEBAB_TESTID, message: 'data-testid must be kebab-case (module-screen-element).' },
]
