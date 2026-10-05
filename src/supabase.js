import { createClient } from '@supabase/supabase-js'
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config'

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
})

export async function login(pin) {
  const { data, error } = await supabase.rpc('apc_login', { p_pin: pin })
  if (error) throw error
  return data
}

export async function listReports(pin) {
  const { data, error } = await supabase.rpc('apc_list_reports', { p_pin: pin })
  if (error) throw error
  return data || []
}

export async function getReport(pin, reportId) {
  const { data, error } = await supabase.rpc('apc_get_report', { p_pin: pin, p_report_id: reportId })
  if (error) throw error
  return data
}

export async function reviewReport(pin, reportId, action, note, reviewedBy) {
  const { data, error } = await supabase.rpc('apc_review_report', {
    p_pin: pin,
    p_report_id: reportId,
    p_action: action,
    p_note: note || '',
    p_reviewed_by: reviewedBy || 'Luis Guillermo Muñoz Quijandría'
  })
  if (error) throw error
  return data
}

export async function setEntryExcluded(pin, entryId, excluded) {
  const { data, error } = await supabase.rpc('apc_web_set_entry_excluded', {
    p_pin: pin,
    p_entry_id: entryId,
    p_excluded: !!excluded
  })
  if (error) throw error
  return data
}
