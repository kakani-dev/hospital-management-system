import type { Locator, Page } from '@playwright/test'

/**
 * #190: registration needs the sex, a date of birth or an age, and a mobile number or a reason for
 * having none. Fills whatever the test left blank (Unknown sex, age 30, "no mobile number").
 */
export async function completeRegistration(scope: Page | Locator): Promise<void> {
  const sex = scope.getByLabel('Sex', { exact: true })
  if (!(await sex.inputValue())) await sex.selectOption('unknown')
  if (!(await scope.getByLabel('Date of birth').inputValue())) await scope.getByTestId('register-age').fill('30')
  if (!(await scope.getByTestId('register-phone').inputValue())) {
    await scope.getByRole('checkbox', { name: 'Patient has no mobile' }).check()
    await scope.getByTestId('register-no-phone-reason').fill('Synthetic test patient')
  }
}
