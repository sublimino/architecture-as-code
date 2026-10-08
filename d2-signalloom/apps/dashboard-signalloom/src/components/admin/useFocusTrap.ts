import { useEffect, useRef, useCallback } from 'react'

export interface UseFocusTrapOptions {
  isOpen: boolean
  onClose?: () => void
  initialFocusRef?: React.RefObject<HTMLElement | null>
  returnFocusRef?: React.RefObject<HTMLElement | null> | null
  preventScroll?: boolean
  closeOnEscape?: boolean
}

export const FOCUSABLE_SELECTOR = [
  'button:not([disabled])',
  '[href]',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(', ')

/**
 * Hook for managing dialog focus, focus trapping, ESC dismissal, and focus restoration.
 */
export function useFocusTrap<T extends HTMLElement = HTMLDivElement>({
  isOpen,
  onClose,
  initialFocusRef,
  returnFocusRef,
  preventScroll = false,
  closeOnEscape = true,
}: UseFocusTrapOptions) {
  const containerRef = useRef<T | null>(null)
  const previousActiveElementRef = useRef<HTMLElement | null>(null)

  // Save previous active element when opening
  useEffect(() => {
    if (isOpen) {
      previousActiveElementRef.current = (document.activeElement as HTMLElement) || null
    }
  }, [isOpen])

  // Focus initial element or first focusable element inside the container
  useEffect(() => {
    if (!isOpen) return

    const timer = setTimeout(() => {
      // If user/test already focused an interactive element inside the container, don't steal focus
      if (
        document.activeElement &&
        containerRef.current &&
        containerRef.current.contains(document.activeElement) &&
        document.activeElement !== containerRef.current
      ) {
        return
      }

      if (initialFocusRef?.current) {
        initialFocusRef.current.focus({ preventScroll })
      } else if (containerRef.current) {
        const focusable = containerRef.current.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)
        if (focusable.length > 0) {
          focusable[0].focus({ preventScroll })
        } else {
          containerRef.current.focus({ preventScroll })
        }
      }
    }, 10)

    return () => clearTimeout(timer)
  }, [isOpen, initialFocusRef, preventScroll])

  // Handle Tab and Escape keys
  const handleKeyDown = useCallback(
    (e: KeyboardEvent | React.KeyboardEvent) => {
      if (!isOpen) return

      if (closeOnEscape && e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        onClose?.()
        return
      }

      if (e.key === 'Tab') {
        if (!containerRef.current) return

        const focusables = Array.from(
          containerRef.current.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
        ).filter((el) => el.offsetParent !== null || el === document.activeElement)

        if (focusables.length === 0) {
          e.preventDefault()
          return
        }

        const firstElement = focusables[0]
        const lastElement = focusables[focusables.length - 1]

        if (e.shiftKey) {
          if (
            document.activeElement === firstElement ||
            !containerRef.current.contains(document.activeElement)
          ) {
            e.preventDefault()
            lastElement.focus()
          }
        } else {
          if (
            document.activeElement === lastElement ||
            !containerRef.current.contains(document.activeElement)
          ) {
            e.preventDefault()
            firstElement.focus()
          }
        }
      }
    },
    [isOpen, closeOnEscape, onClose],
  )

  // Global document listener for Escape key to ensure dismissal anywhere in the window
  useEffect(() => {
    if (!isOpen || !closeOnEscape) return

    const onDocKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose?.()
      }
    }

    document.addEventListener('keydown', onDocKeyDown)
    return () => document.removeEventListener('keydown', onDocKeyDown)
  }, [isOpen, closeOnEscape, onClose])

  // Restore focus to returnFocusRef or previously active element on unmount / close
  useEffect(() => {
    return () => {
      const targetToFocus = returnFocusRef?.current ?? previousActiveElementRef.current
      if (targetToFocus && typeof targetToFocus.focus === 'function') {
        // Small delay to allow react re-render / cleanup
        setTimeout(() => {
          try {
            targetToFocus.focus()
          } catch {
            // Element may have been removed from DOM
          }
        }, 10)
      }
    }
  }, [returnFocusRef])

  return { containerRef, handleKeyDown, previousActiveElementRef }
}
