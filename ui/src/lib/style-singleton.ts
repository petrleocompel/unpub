// A stand-in for `react-style-singleton`, which `react-remove-scroll` (the
// scroll lock of Radix dialogs and menus) uses to add a <style> element.
// The Content-Security-Policy (`style-src 'self'`) refuses such elements, so
// this one adopts a constructed stylesheet instead: CSSOM changes are not
// subject to the policy. Without constructable stylesheets it does nothing,
// which only leaves the page scrollable behind a dialog.
import { useEffect, type FC } from 'react'

type Sheet = { add(style: string): void; remove(): void }

function supported(): boolean {
  return (
    typeof document !== 'undefined' &&
    'adoptedStyleSheets' in document &&
    typeof CSSStyleSheet !== 'undefined' &&
    'replaceSync' in CSSStyleSheet.prototype
  )
}

export const stylesheetSingleton = (): Sheet => {
  let counter = 0
  let sheet: CSSStyleSheet | null = null
  return {
    add(style: string) {
      if (counter === 0 && supported()) {
        sheet = new CSSStyleSheet()
        sheet.replaceSync(style)
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]
      }
      counter++
    },
    remove() {
      counter--
      if (counter === 0 && sheet) {
        const current = sheet
        document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== current)
        sheet = null
      }
    },
  }
}

export const styleHookSingleton = () => {
  const sheet = stylesheetSingleton()
  return (styles: string, isDynamic?: boolean) => {
    useEffect(() => {
      sheet.add(styles)
      return () => sheet.remove()
      // Mirrors the original: styles change only when marked dynamic.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [styles && isDynamic])
  }
}

export const styleSingleton = () => {
  const useStyle = styleHookSingleton()
  const Sheet: FC<{ styles: string; dynamic?: boolean }> = ({ styles, dynamic }) => {
    useStyle(styles, dynamic)
    return null
  }
  return Sheet
}
