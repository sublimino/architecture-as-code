import '@testing-library/jest-dom'
import { beforeEach } from 'vitest'
import { resetFakeData } from './api/fakeData'

beforeEach(() => {
  resetFakeData()
})
