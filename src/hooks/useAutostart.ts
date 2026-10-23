import { invoke } from '@tauri-apps/api/core'
import { useState, useEffect, useCallback } from 'react'

// Custom autostart commands that use the wrapper script on Linux
// instead of the direct binary, ensuring proper environment setup
const enable = () => invoke('autostart_enable')
const disable = () => invoke('autostart_disable')
const isEnabled = () => invoke<boolean>('autostart_is_enabled')
const migrate = () => invoke<boolean>('autostart_migrate')
// Remembers the choice, then enables or disables the entry to match
const setChoice = (enabled: boolean) => invoke('set_start_at_login', { enabled })

export function useAutostart() {
  const [enabled, setEnabled] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const checkStatus = useCallback(async () => {
    try {
      const value = await isEnabled()
      setEnabled(value)
      setError(null)
    } catch (e) {
      console.error('Failed to check autostart status:', e)
      setError(String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    const migrateAndCheck = async () => {
      try {
        // First, try to migrate any old autostart entries
        const migrated = await migrate()
        if (migrated) {
          console.log('[Autostart] Migrated old autostart entry to use wrapper')
        }
        // Then check the current status
        await checkStatus()
      } catch (e) {
        console.error('Failed to migrate/check autostart:', e)
        setError(String(e))
        setLoading(false)
      }
    }

    // On mount, try to migrate old autostart entries and check status
    migrateAndCheck()
  }, [checkStatus])

  // Saves the "Start at login" choice and applies it, then shows what is really on disk: the
  // result of the call is not trusted, `enabled` always comes from a fresh read. True only when
  // the call succeeded and the real state is the one asked for.
  const applyStartAtLogin = async (want: boolean): Promise<boolean> => {
    setLoading(true)
    setError(null)
    let problem: string | null = null
    try {
      await setChoice(want)
    } catch (e) {
      console.error('Failed to change start at login:', e)
      problem = String(e)
    }
    try {
      const actual = await isEnabled()
      setEnabled(actual)
      if (problem === null && actual !== want) {
        problem = `Start at login is still ${actual ? 'on' : 'off'}`
      }
    } catch (e) {
      console.error('Failed to check autostart status:', e)
      problem ??= String(e)
    }
    setError(problem)
    setLoading(false)
    return problem === null
  }

  const toggle = async (): Promise<boolean> => {
    setLoading(true)
    setError(null)
    try {
      if (enabled) {
        await disable()
        setEnabled(false)
        return false
      } else {
        await enable()
        setEnabled(true)
        return true
      }
    } catch (e) {
      console.error('Failed to toggle autostart:', e)
      setError(String(e))
      return enabled
    } finally {
      setLoading(false)
    }
  }

  const enableAutostart = async (): Promise<boolean> => {
    if (enabled) return true
    setLoading(true)
    setError(null)
    try {
      await enable()
      setEnabled(true)
      return true
    } catch (e) {
      console.error('Failed to enable autostart:', e)
      setError(String(e))
      return false
    } finally {
      setLoading(false)
    }
  }

  const disableAutostart = async (): Promise<boolean> => {
    if (!enabled) return true
    setLoading(true)
    setError(null)
    try {
      await disable()
      setEnabled(false)
      return true
    } catch (e) {
      console.error('Failed to disable autostart:', e)
      setError(String(e))
      return false
    } finally {
      setLoading(false)
    }
  }

  return {
    enabled,
    loading,
    error,
    toggle,
    applyStartAtLogin,
    enableAutostart,
    disableAutostart,
    checkStatus,
  }
}
