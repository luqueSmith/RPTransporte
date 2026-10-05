import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  AlertTriangle, ArrowDownLeft, ArrowUpRight, CalendarDays, CheckCircle2, ChevronDown, CircleAlert, Download, Eye, FileSpreadsheet, FileText, Filter,
  LogOut, MessageSquareText, MoonStar, RefreshCw, RotateCcw, Route, SunMedium, WalletCards, X
} from 'lucide-react'
import { getReport, listReports, login, reviewReport, setEntryExcluded } from './supabase'
import './styles.css'

const asset = name => `${import.meta.env.BASE_URL}${name}`
const money = n => `S/ ${Number(n || 0).toLocaleString('es-PE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
const cleanText = value => {
  const text=String(value??'').trim()
  return !text || /^(null|undefined)$/i.test(text) ? '' : text
}
const formatDate = s => {
  if (!s) return '—'
  const [y,m,d] = String(s).slice(0,10).split('-')
  return y && m && d ? `${d}/${m}/${y}` : s
}
const longDate = s => {
  if (!s) return ''
  const d = new Date(`${String(s).slice(0,10)}T12:00:00`)
  return new Intl.DateTimeFormat('es-PE',{day:'numeric',month:'long',year:'numeric'}).format(d)
}
const statusMeta = {
  draft: ['En preparación','neutral'], submitted: ['En revisión','info'],
  approved: ['Aprobado','ok'], correction_requested: ['Requiere corrección','warn']
}
const movementDetail = e => {
  if (e.detail) return e.detail
  if (e.origin || e.destination) return `${e.origin || '—'} → ${e.destination || '—'}`
  return e.entry_type === 'credit' ? 'Entrega registrada' : 'Gasto de transporte'
}
const isLost = e => /extraviad|perdid|sustra/i.test(e.support_note || '')
const isShown = e => /ya mostr/i.test(e.support_note || '')
const supportType = e => cleanText(e?.support_type).toLowerCase()
const isExcluded = e => !!e?.is_excluded
const supportAsset = e => cleanText(e?.support_asset)
const assetLooksDeclaration = e => /declaraci[oó]n|declaration/i.test(supportAsset(e))

// La web NO debe asumir que existe una boleta solo porque un registro antiguo
// conserve support_type='receipt' o 'receipt_declaration'. La prueba fuerte de
// una boleta es la imagen/base64, un archivo de boleta o el histórico "Ya mostrada".
const hasReceiptFile = e => e?.entry_type==='expense' && !isLost(e) && !!(
  cleanText(e?.receipt_image_base64) ||
  (supportAsset(e) && supportType(e).includes('receipt') && !assetLooksDeclaration(e))
)
const hasDeclaration = e => e?.entry_type==='expense' && !!(
  supportType(e).includes('declaration') ||
  assetLooksDeclaration(e) ||
  cleanText(e?.declaration_reason) ||
  cleanText(e?.declaration_place_date)
)
const hasReceiptFallback = e => e?.entry_type==='expense' && !isLost(e) && !!(
  isShown(e) || (supportType(e)==='receipt' && !hasDeclaration(e))
)
const hasReceipt = e => hasReceiptFile(e) || hasReceiptFallback(e)
const canOpenReceipt = e => !!(
  cleanText(e?.receipt_image_base64) ||
  (supportAsset(e) && supportType(e).includes('receipt') && !assetLooksDeclaration(e))
)

// Un gasto usa un solo sustento visible: boleta O declaración jurada.
// 1) Si hay una boleta REAL (imagen/archivo), gana la boleta.
// 2) Si no hay archivo de boleta pero sí datos de declaración, se muestra la declaración.
// 3) Los indicadores heredados de versiones antiguas solo se usan como último recurso.
const supportKind = e => {
  if(e?.entry_type!=='expense') return 'none'
  if(isLost(e)) return hasDeclaration(e) ? 'declaration' : 'lost'
  if(hasReceiptFile(e)) return 'receipt'
  if(hasDeclaration(e)) return 'declaration'
  if(hasReceiptFallback(e)) return 'receipt'
  return 'none'
}
const canOpenDeclaration = e => supportKind(e)==='declaration' && hasDeclaration(e)
const canOpenSupport = e => supportKind(e)==='receipt' ? canOpenReceipt(e) : canOpenDeclaration(e)
const receiptDeliveryText = e => e?.receipt_delivered ? 'Entregada' : 'Pendiente de entregar'
const supportExportLabel = e => {
  const kind=supportKind(e)
  let label='—'
  if(kind==='receipt') label=`Boleta · ${receiptDeliveryText(e)}`
  else if(kind==='declaration') label='Declaración jurada'
  else if(kind==='lost') label='Boleta extraviada'
  return isExcluded(e) ? `NO CONSIDERADO · ${label}` : label
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const friendlyError = e => {
  const m = String(e?.message || e || '')
  if (/apc_web_set_entry_excluded|schema cache|could not find the function/i.test(m)) return 'La revisión de movimientos todavía no está activada en Supabase. Ejecuta el SQL v1.23 una sola vez y luego pulsa Actualizar.'
  if (/failed to fetch|network|load failed|fetch/i.test(m)) return 'La conexión con el reporte está tardando. Intenta nuevamente en unos segundos.'
  return m || 'No se pudo completar la operación'
}
async function retryCall(fn, attempts=2){
  let last
  for(let i=0;i<attempts;i++){
    try{return await fn()}catch(e){last=e;if(i<attempts-1)await delay(500*(i+1))}
  }
  throw last
}
const sortBundles = list => [...list].sort((a,b)=>{
  if(!!a.report?.is_closed!==!!b.report?.is_closed) return a.report?.is_closed?1:-1
  return String(b.report?.period_start||'').localeCompare(String(a.report?.period_start||''))
})

// Orden fijo de movimientos: fecha más reciente primero.
// Si dos movimientos tienen la misma fecha, se conserva su orden original.
const sortEntriesNewestFirst = entries => [...(entries || [])]
  .map((entry,index)=>({entry,index}))
  .sort((a,b)=>{
    const da=String(a.entry?.entry_date||'').slice(0,10)
    const db=String(b.entry?.entry_date||'').slice(0,10)
    if(da!==db) return db.localeCompare(da)
    return a.index-b.index
  })
  .map(x=>x.entry)

const normalizeBundleEntries = bundle => bundle ? {
  ...bundle,
  entries: sortEntriesNewestFirst(bundle.entries || [])
} : bundle

// Recalcula los importes visibles de la WEB sin tocar los datos de la APK.
// Los movimientos fuera del cálculo siguen existiendo y pueden restaurarse.
const recalcWebSummary = bundle => {
  if(!bundle) return bundle
  const entries=bundle.entries||[]
  const considered=entries.filter(e=>!isExcluded(e))
  const received=considered.filter(e=>e.entry_type==='credit').reduce((n,e)=>n+Number(e.amount||0),0)
  const spent=considered.filter(e=>e.entry_type==='expense').reduce((n,e)=>n+Number(e.amount||0),0)
  const raw=received-spent
  return {
    ...bundle,
    summary:{
      ...(bundle.summary||{}),
      received,
      spent,
      raw_balance:raw,
      balance:bundle.report?.is_closed?0:raw,
      excluded_count:entries.filter(isExcluded).length
    }
  }
}

const inDateRange = (date, from, to) => {
  const d=String(date||'').slice(0,10)
  if(!d) return false
  if(from && d<from) return false
  if(to && d>to) return false
  return true
}

const normalizeRouteText = value => String(value||'')
  .normalize('NFD').replace(/[\u0300-\u036f]/g,'')
  .toUpperCase().replace(/\s+/g,' ').trim()

const HOME_MARKERS = ['PISCO','CRUCE PISCO']
const WORK_MARKERS = ['ICA','BARRIO CHINO']
const containsMarker = (text,markers) => markers.some(m=>text.includes(m))

const routeEndpoints = e => {
  if(e?.origin || e?.destination){
    return [normalizeRouteText(e.origin),normalizeRouteText(e.destination)]
  }
  const raw=normalizeRouteText(movementDetail(e))
  const parts=raw.split(/\s*(?:→|->|—|–|-)\s*/).filter(Boolean)
  if(parts.length>=2) return [parts[0],parts[parts.length-1]]
  return [raw,'']
}

const routeDirection = e => {
  if(e?.entry_type!=='expense') return 'none'
  const [from,to]=routeEndpoints(e)
  const fromHome=containsMarker(from,HOME_MARKERS)
  const toHome=containsMarker(to,HOME_MARKERS)
  const fromWork=containsMarker(from,WORK_MARKERS)
  const toWork=containsMarker(to,WORK_MARKERS)
  if(fromHome && toWork) return 'outbound'
  if(fromWork && toHome) return 'return'
  return 'other'
}

const matchesMovementFilters = (e,{dateFrom,dateTo,typeFilter,directionFilter}) => {
  if((dateFrom||dateTo) && !inDateRange(e.entry_date,dateFrom,dateTo)) return false
  if(typeFilter!=='all' && e.entry_type!==typeFilter) return false
  if(directionFilter!=='all' && routeDirection(e)!==directionFilter) return false
  return true
}

function ApcLogo({className=''}) {
  return <span className={`apc-logo-pair ${className}`}>
    <img className="apc-logo-light" src={asset('apc-logo-light.webp')} alt="APC Corporacion"/>
    <img className="apc-logo-dark" src={asset('apc-logo-dark.webp')} alt="APC Corporacion"/>
  </span>
}

function App(){
  const [pin,setPin] = useState(sessionStorage.getItem('apc_pin') || '')
  const [logged,setLogged] = useState(false)
  const [bundles,setBundles] = useState([])
  const [loading,setLoading] = useState(false)
  const [error,setError] = useState('')
  const [modal,setModal] = useState(null)
  const [entryBusy,setEntryBusy] = useState('')
  const [theme,setTheme] = useState(localStorage.getItem('apc_theme') || 'light')
  const [dateFrom,setDateFrom] = useState('')
  const [dateTo,setDateTo] = useState('')
  const [typeFilter,setTypeFilter] = useState('all')
  const [directionFilter,setDirectionFilter] = useState('all')

  useEffect(()=>{document.documentElement.dataset.theme=theme;localStorage.setItem('apc_theme',theme)},[theme])
  useEffect(()=>{ if(pin && sessionStorage.getItem('apc_pin')) doLogin(pin, true) },[])

  const current = useMemo(()=>bundles.find(b=>!b.report?.is_closed && !b.report?.period_end) || null,[bundles])
  const pending = useMemo(()=>bundles.filter(b=>!b.report?.is_closed && !!b.report?.period_end).sort((a,b)=>String(b.report.period_start).localeCompare(String(a.report.period_start))),[bundles])
  const closed = useMemo(()=>bundles.filter(b=>b.report?.is_closed).sort((a,b)=>String(b.report.period_start).localeCompare(String(a.report.period_start))),[bundles])
  const movementFilterActive=!!(dateFrom||dateTo||typeFilter!=='all'||directionFilter!=='all')
  const filterConfig={dateFrom,dateTo,typeFilter,directionFilter}
  const filterEntries=entries=>sortEntriesNewestFirst(movementFilterActive?(entries||[]).filter(e=>matchesMovementFilters(e,filterConfig)):(entries||[]))
  const periodHasMatches=b=>!movementFilterActive||filterEntries(b.entries).length>0
  const matchCount=useMemo(()=>bundles.reduce((n,b)=>n+filterEntries(b.entries).length,0),[bundles,dateFrom,dateTo,typeFilter,directionFilter])

  async function doLogin(value=pin, quiet=false){
    setLoading(true); setError('')
    try{
      const r = await retryCall(()=>login(value), 2)
      if(!r?.ok) throw new Error('PIN incorrecto')
      sessionStorage.setItem('apc_pin',value); setPin(value); setLogged(true)
      await refreshAll(value)
    }catch(e){ if(!quiet) setError(friendlyError(e)) }
    finally{setLoading(false)}
  }
  async function refreshAll(p=pin){
    setLoading(true);setError('')
    try{
      const rows=await retryCall(()=>listReports(p), 2)
      if(!(rows||[]).length){setBundles([]);return}

      const ordered=[...(rows||[])].sort((a,b)=>{
        if(!!a.is_closed!==!!b.is_closed) return a.is_closed?1:-1
        return String(b.period_start||'').localeCompare(String(a.period_start||''))
      })
      const currentRow=ordered.find(r=>!r.is_closed&&!r.period_end) || ordered[0]
      let currentBundle=null

      if(currentRow){
        currentBundle=normalizeBundleEntries(await retryCall(()=>getReport(p,currentRow.id),2))
        setBundles(prev=>sortBundles([currentBundle,...prev.filter(b=>b.report?.id!==currentBundle.report?.id)]))
      }

      const restRows=ordered.filter(r=>r.id!==currentRow?.id)
      const results=await Promise.allSettled(restRows.map(r=>retryCall(()=>getReport(p,r.id),2)))
      const rest=results.filter(x=>x.status==='fulfilled').map(x=>normalizeBundleEntries(x.value))
      const failed=results.filter(x=>x.status==='rejected').length
      setBundles(sortBundles([...(currentBundle?[currentBundle]:[]),...rest]))
      if(failed) setError('El reporte actual cargó, pero algunas evidencias anteriores tardaron en responder. Puedes pulsar Actualizar.')
    }catch(e){setError(friendlyError(e))}
    finally{setLoading(false)}
  }
  async function review(reportId,action,note,reviewedBy){
    if(!reportId) return
    setLoading(true);setError('')
    try{await retryCall(()=>reviewReport(pin,reportId,action,note,reviewedBy),2);await refreshAll()}
    catch(e){setError(friendlyError(e))}
    finally{setLoading(false)}
  }
  async function changeEntryIncluded(entry, exclude){
    if(!entry?.id || entryBusy) return
    setError('')
    setEntryBusy(entry.id)

    // Cambio inmediato en pantalla: no pregunta confirmación y el usuario
    // siempre puede revertirlo con "Volver a incluir".
    setBundles(prev=>prev.map(bundle=>{
      if(!bundle.entries?.some(e=>e.id===entry.id)) return bundle
      const entries=bundle.entries.map(e=>e.id===entry.id?{...e,is_excluded:!!exclude,excluded_at:exclude?new Date().toISOString():null}:e)
      return recalcWebSummary({...bundle,entries})
    }))

    try{
      await retryCall(()=>setEntryExcluded(pin,entry.id,exclude),2)
      // Refresca desde Supabase para dejar la vista 100% alineada con la base.
      await refreshAll()
    }catch(e){
      setError(friendlyError(e))
      // Si falló el guardado, recupera el estado real de Supabase.
      try{await refreshAll()}catch{}
    }finally{
      setEntryBusy('')
    }
  }
  function logout(){sessionStorage.removeItem('apc_pin');setLogged(false);setBundles([]);setPin('')}

  if(!logged) return <Login pin={pin} setPin={setPin} onLogin={()=>doLogin()} loading={loading} error={error} theme={theme} setTheme={setTheme}/>
  return <div className="app-shell">
    <header className="topbar">
      <button className="brand brand-home" onClick={()=>window.scrollTo({top:0,behavior:'smooth'})} title="Volver arriba" aria-label="Volver al inicio"><ApcLogo className="brand-logo"/><div className="brand-copy"><strong>APC Corporacion</strong><span>Control de transporte</span></div></button>
      <div className="top-actions">
        <button className="theme-switch" onClick={()=>setTheme(theme==='dark'?'light':'dark')} title={theme==='dark'?'Cambiar a modo día':'Cambiar a modo noche'}>
          {theme==='dark'?<SunMedium size={19}/>:<MoonStar size={19}/>}
          <span>{theme==='dark'?'Modo día':'Modo noche'}</span>
        </button>
        <button className="icon-btn" onClick={()=>refreshAll()} title="Actualizar"><RefreshCw size={19}/></button>
        <button className="ghost" onClick={logout}><LogOut size={17}/> Salir</button>
      </div>
    </header>
    <main className="content unified-content">
      {error && <div className="error-banner"><CircleAlert size={18}/>{error}</div>}
      {loading && <div className="loading-line"><RefreshCw size={16} className="spin"/> Actualizando…</div>}
      {!bundles.length && !loading ? <Empty/> : <>
        <section className="overview-head">
          <div><span className="eyebrow">REPORTE DE TRANSPORTE</span><h1>Cuenta actual y períodos liquidados</h1><p>Todo el transporte está reunido en una sola vista. Las cuentas antiguas ya no afectan el saldo actual.</p></div>
          <div className="download-row top-downloads">
            <button className="primary" onClick={()=>downloadAllPdf(bundles)}><Download size={18}/> Descargar PDF</button>
            <button className="secondary" onClick={()=>downloadAllExcel(bundles)}><FileSpreadsheet size={18}/> Descargar Excel</button>
          </div>
        </section>

        {!current && <MovementFilters dateFrom={dateFrom} dateTo={dateTo} setDateFrom={setDateFrom} setDateTo={setDateTo} typeFilter={typeFilter} setTypeFilter={setTypeFilter} directionFilter={directionFilter} setDirectionFilter={setDirectionFilter} active={movementFilterActive}/>}

        {current && <>
          <div className="section-marker current-marker"><div className="marker-copy"><span>PERÍODO ACTUAL</span><small>{formatDate(current.report.period_start)} – hoy</small></div><b>Cuenta abierta</b></div>
          <PeriodSection
            bundle={{...current,entries:filterEntries(current.entries)}}
            current
            filtered={movementFilterActive}
            filterControl={<MovementFilters dateFrom={dateFrom} dateTo={dateTo} setDateFrom={setDateFrom} setDateTo={setDateTo} typeFilter={typeFilter} setTypeFilter={setTypeFilter} directionFilter={directionFilter} setDirectionFilter={setDirectionFilter} active={movementFilterActive}/>}
            onEvidence={(item,kind)=>setModal({item,kind,report:current.report})}
            onEntryReview={changeEntryIncluded}
            entryBusy={entryBusy}
          />
          {current.report.status!=='draft' && <ReviewPanel bundle={current} onReview={review}/>} 
        </>}

        {!!pending.filter(periodHasMatches).length && <div className="past-title"><span className="eyebrow">ENVIADOS</span><h2>Pendientes de revisión o liquidación</h2><p>Estos periodos ya terminaron, pero todavía no se han marcado como cuentas liquidadas desde la APK.</p></div>}
        {pending.filter(periodHasMatches).map(b=><React.Fragment key={b.report.id}>
          <div className="section-marker pending-marker"><div className="marker-copy"><span>PERÍODO FINALIZADO</span><small>{formatDate(b.report.period_start)} – {formatDate(b.report.period_end)}</small></div><b>{statusMeta[b.report.status]?.[0]||'En revisión'}</b></div>
          <PeriodSection bundle={{...b,entries:filterEntries(b.entries)}} pending filtered={movementFilterActive} onEvidence={(item,kind)=>setModal({item,kind,report:b.report})} onEntryReview={changeEntryIncluded} entryBusy={entryBusy}/>
          <ReviewPanel bundle={b} onReview={review}/>
        </React.Fragment>)}

        {!!closed.filter(periodHasMatches).length && <div className="past-title"><span className="eyebrow">CUENTAS ANTERIORES</span><h2>Períodos liquidados</h2><p>Estos períodos quedaron saldados al finalizar. Su saldo pendiente actual es S/ 0.00.</p></div>}
        {closed.filter(periodHasMatches).map(b=><React.Fragment key={b.report.id}>
          <div className="section-marker closed-marker"><div className="marker-copy"><span>PERÍODO CERRADO</span><small>{formatDate(b.report.period_start)} – {formatDate(b.report.period_end)}</small></div><b><CheckCircle2 size={15}/> Liquidado</b></div>
          <PeriodSection bundle={{...b,entries:filterEntries(b.entries)}} filtered={movementFilterActive} collapsible onEvidence={(item,kind)=>setModal({item,kind,report:b.report})}/>
        </React.Fragment>)}
        {movementFilterActive && matchCount===0 && <div className="filter-empty"><CalendarDays size={28}/><strong>No hay movimientos que coincidan con los filtros</strong><span>Prueba con otros filtros o límpialos.</span></div>}
      </>}
    </main>
    {modal && <EvidenceModal item={modal.item} kind={modal.kind} report={modal.report} onClose={()=>setModal(null)}/>} 
  </div>
}

function MovementFilters({dateFrom,dateTo,setDateFrom,setDateTo,typeFilter,setTypeFilter,directionFilter,setDirectionFilter,active}){
  const openPicker=id=>{const el=document.getElementById(id);if(el?.showPicker)el.showPicker();else el?.focus()}
  const openNext=()=>openPicker(!dateFrom?'date-from':(!dateTo?'date-to':'date-from'))
  const reset=()=>{setDateFrom('');setDateTo('');setTypeFilter('all');setDirectionFilter('all')}
  return <div className={`movement-date-filter movement-filter-panel compact-date-filter ${active?'active':''}`}>
    {active && <button type="button" className="filter-reset" aria-label="Quitar todos los filtros" title="Quitar filtros" onClick={reset}><X size={14}/></button>}
    <div className="movement-filter-controls extended-filter-controls">
      <label className="filter-choice select-choice">
        <span>Movimiento</span>
        <select value={typeFilter} onChange={e=>setTypeFilter(e.target.value)}>
          <option value="all">Todos</option>
          <option value="expense">Solo gastos</option>
          <option value="credit">Solo créditos</option>
        </select>
      </label>
      <label className="filter-choice select-choice route-filter-choice">
        <span>Trayecto</span>
        <select value={directionFilter} onChange={e=>setDirectionFilter(e.target.value)}>
          <option value="all">Todas las rutas</option>
          <option value="outbound">Ida al trabajo · Pisco → Ica / Barrio Chino</option>
          <option value="return">Regreso a Pisco · Ica / Barrio Chino → Pisco</option>
        </select>
      </label>
      <label className="date-choice simple-date-choice">
        <span>Desde</span>
        <input id="date-from" type="date" value={dateFrom} max={dateTo||undefined} onClick={e=>e.currentTarget.showPicker?.()} onChange={e=>setDateFrom(e.target.value)}/>
      </label>
      <label className="date-choice simple-date-choice">
        <span>Hasta</span>
        <input id="date-to" type="date" value={dateTo} min={dateFrom||undefined} onClick={e=>e.currentTarget.showPicker?.()} onChange={e=>setDateTo(e.target.value)}/>
      </label>
      <button type="button" className="single-calendar-button" onClick={openNext} aria-label="Elegir fecha" title="Elegir fecha"><CalendarDays size={18}/></button>
    </div>
  </div>
}

function Login({pin,setPin,onLogin,loading,error,theme,setTheme}){
  return <div className="login-page"><button className="login-theme" onClick={()=>setTheme(theme==='dark'?'light':'dark')}>{theme==='dark'?<SunMedium size={19}/>:<MoonStar size={19}/>}<span>{theme==='dark'?'Modo día':'Modo noche'}</span></button><div className="login-card">
    <ApcLogo className="login-logo"/>
    <h1>Reporte de transporte</h1><p>Consulta el reporte actual, las cuentas liquidadas, boletas y declaraciones juradas.</p>
    <label>PIN de acceso</label><input autoFocus inputMode="numeric" value={pin} onChange={e=>setPin(e.target.value)} onKeyDown={e=>e.key==='Enter'&&onLogin()} placeholder="Ingresa el PIN"/>
    {error&&<div className="field-error">{error}</div>}
    <button className="primary wide" onClick={onLogin} disabled={loading||!pin}>{loading?'Ingresando…':'Ver reporte'}</button>
  </div></div>
}

function PeriodSection({bundle,current=false,pending=false,filtered=false,collapsible=false,filterControl=null,onEvidence,onEntryReview,entryBusy}){
  const {report,summary,entries=[]}=bundle
  const status=statusMeta[report.status]||[report.status,'neutral']
  const period=report.period_end?`${longDate(report.period_start)} – ${longDate(report.period_end)}`:`Desde ${longDate(report.period_start)}`
  const raw=Number(summary.raw_balance ?? (Number(summary.received)-Number(summary.spent)))
  const adjustment=Math.abs(raw)
  const active=current||pending
  return <section className={`period-card ${current?'current-period':pending?'pending-period':'closed-period'}`}>
    <div className="period-heading"><div><h2>{period}</h2><p>{report.owner_name} · DNI {report.owner_dni}</p></div>{active?<span className={`status ${status[1]}`}>{status[0]}</span>:<span className="status settled">Cuenta liquidada</span>}</div>
    <div className={`summary-grid ${active?'':'closed-summary'}`}>
      <div className="balance-card"><span>{current?'Saldo disponible':pending?'Saldo por liquidar':'Saldo pendiente actual'}</span><strong>{money(active?summary.balance:0)}</strong><small>{current?'Recibido menos gastos':pending?'El período terminó, pero la cuenta aún no se marcó como liquidada':'Cuenta ya saldada al cierre'}</small></div>
      <div className="metric"><span>Recibido</span><strong className="received">{money(summary.received)}</strong></div>
      <div className="metric"><span>Gastado</span><strong className="spent">{money(summary.spent)}</strong></div>
      {!active && <div className="metric closure"><span>{raw>0?'Devuelto al cierre':raw<0?'Regularización de cierre':'Cierre'}</span><strong>{money(adjustment)}</strong></div>}
    </div>
    {!active && <div className="closure-note"><CheckCircle2 size={17}/><div><strong>Cuenta liquidada · saldo S/ 0.00</strong><span>{report.closure_note || (raw>0?'El saldo sobrante fue devuelto al finalizar el período.':raw<0?'La diferencia pendiente fue regularizada al finalizar el período.':'El período cerró sin saldo pendiente.')}</span></div></div>}
    {filtered && <div className="period-filter-note"><Filter size={14}/> Mostrando solo movimientos que coinciden con los filtros seleccionados. Los totales superiores corresponden al período completo.</div>}

    {collapsible ? <details className="closed-movements-details"><summary><span><CalendarDays size={16}/> Movimientos y sustentos</span><b>{entries.length} {entries.length===1?'registro':'registros'}</b><ChevronDown size={18}/></summary><div className="closed-movements-body"><MovementTable entries={entries} onEvidence={onEvidence} allowReview={false}/></div></details> : <MovementTable entries={entries} onEvidence={onEvidence} filterControl={filterControl} allowReview={active} onEntryReview={onEntryReview} entryBusy={entryBusy}/>}
  </section>
}

function MovementTable({entries,onEvidence,filterControl=null,allowReview=false,onEntryReview,entryBusy}){
  entries=sortEntriesNewestFirst(entries)
  return <>
    <div className="movements-heading">
      <div className="movements-title">
        <span className="movements-icon"><WalletCards size={20}/></span>
        <div>
          <span className="eyebrow">MOVIMIENTOS</span>
          <h3>Detalle de transporte</h3>
          <p>{entries.length} {entries.length===1?'registro':'registros'}{entries.some(isExcluded)?` · ${entries.filter(isExcluded).length} no considerado(s)`:''} · Cada fila indica qué ocurrió, cuánto fue y qué documento lo sustenta.</p>
        </div>
      </div>
      <div className="movements-tools">
        <div className="movement-legend" aria-label="Leyenda de movimientos">
          <span className="legend-credit"><ArrowDownLeft size={14}/> Dinero recibido (+)</span>
          <span className="legend-expense"><ArrowUpRight size={14}/> Pasaje / gasto (−)</span>
        </div>
        {filterControl}
      </div>
    </div>

    <div className="movement-help"><span className="movement-help-credit">+ suma al saldo</span><span className="movement-help-expense">− descuenta del saldo</span><span>“Quitar del cálculo” no borra el movimiento: solo cambia los totales de esta web. Puedes volver a incluirlo con un toque.</span></div>

    <div className="desktop-movement-table">
      <div className="table-wrap movement-table-wrap spreadsheet-wrap">
        <table className="movement-table friendly-movement-table spreadsheet-table">
          <thead>
            <tr>
              <th className="col-number">N.º</th>
              <th className="col-date">Fecha</th>
              <th className="col-type">Movimiento</th>
              <th className="col-detail">Detalle / ruta</th>
              <th className="col-time">Hora</th>
              <th className="right col-amount">Importe</th>
              <th className="col-support">Sustento</th>
              {allowReview && <th className="col-review">Cálculo</th>}
            </tr>
          </thead>
          <tbody>
            {!entries.length && <tr className="movement-empty-row"><td colSpan={allowReview?8:7}><CalendarDays size={18}/><span>No hay movimientos que coincidan con estas fechas.</span></td></tr>}
            {entries.map((e,index)=>{
              const isCredit=e.entry_type==='credit'
              return <tr key={e.id} className={`movement-row ${e.entry_type} ${isExcluded(e)?'excluded':''}`}>
                <td data-label="N.º" className="movement-number-cell"><span className="row-number">{index+1}</span></td>
                <td data-label="Fecha" className="movement-date-cell"><span className="date-chip"><CalendarDays size={14}/>{formatDate(e.entry_date)}</span></td>
                <td data-label="Movimiento" className="movement-type-cell"><span className={`type-pill ${e.entry_type}`}>{isCredit?<ArrowDownLeft size={13}/>:<ArrowUpRight size={13}/>} {isCredit?'RECIBIDO':'GASTO'}</span></td>
                <td data-label="Detalle / ruta" className="movement-detail-cell">
                  <div className="table-detail-copy">
                    <strong>{isCredit?'Dinero recibido':'Pasaje / transporte'}</strong>
                    <span>{movementDetail(e)}</span>
                  </div>
                </td>
                <td data-label="Hora" className="movement-time-cell"><span className="table-time">{cleanText(e.issue_time)||'—'}</span></td>
                <td data-label="Importe" className={`right amount ${e.entry_type} movement-amount-cell`}><span className="amount-box"><b>{isCredit?'+':'−'}{money(e.amount)}</b></span></td>
                <td data-label="Sustento" className="movement-support-cell"><SupportCell item={e} onOpen={(kind)=>onEvidence(e,kind)}/></td>
                {allowReview && <td data-label="Cálculo" className="movement-review-cell"><EntryReviewControl item={e} onChange={onEntryReview} busy={entryBusy===e.id}/></td>}
              </tr>
            })}
          </tbody>
        </table>
      </div>
    </div>

    <div className="mobile-movement-list" aria-label="Movimientos de transporte">
      {!entries.length && <div className="mobile-movement-empty"><CalendarDays size={18}/><span>No hay movimientos que coincidan con estas fechas.</span></div>}
      {entries.map((e,index)=>{
        const isCredit=e.entry_type==='credit'
        return <article key={`mobile-${e.id}`} className={`mobile-movement-card ${e.entry_type} ${isExcluded(e)?'excluded':''}`}>
          <div className="mobile-movement-card-head">
            <span className="mobile-row-number">{index+1}</span>
            <span className="mobile-card-date"><CalendarDays size={15}/>{formatDate(e.entry_date)}</span>
            <span className={`mobile-card-type ${e.entry_type}`}>{isCredit?<ArrowDownLeft size={14}/>:<ArrowUpRight size={14}/>} {isCredit?'RECIBIDO':'GASTO'}</span>
          </div>

          <div className="mobile-card-detail">
            <span className="mobile-field-label">{isCredit?'Detalle':'Ruta / detalle'}</span>
            <strong>{movementDetail(e)}</strong>
          </div>

          <div className="mobile-card-summary">
            <div className="mobile-summary-cell">
              <span>Hora</span>
              <strong>{cleanText(e.issue_time)||'—'}</strong>
            </div>
            <div className={`mobile-summary-cell mobile-summary-amount ${e.entry_type}`}>
              <span>Importe</span>
              <strong>{isCredit?'+':'−'}{money(e.amount)}</strong>
            </div>
          </div>

          <div className="mobile-card-support">
            <span className="mobile-field-label">Sustento</span>
            <SupportCell item={e} onOpen={(kind)=>onEvidence(e,kind)}/>
          </div>
          {allowReview && <div className="mobile-card-review">
            <span className="mobile-field-label">Cálculo del reporte</span>
            <EntryReviewControl item={e} onChange={onEntryReview} mobile busy={entryBusy===e.id}/>
          </div>}
        </article>
      })}
    </div>
  </>
}

function EntryReviewControl({item,onChange,mobile=false,busy=false}){
  const excluded=isExcluded(item)
  if(excluded) return <div className={`entry-review-control excluded ${mobile?'mobile':''}`}>
    <span className="entry-review-state"><CircleAlert size={13}/> Fuera del cálculo</span>
    <button type="button" disabled={busy} className="entry-review-button restore" onClick={()=>onChange?.(item,false)}><RotateCcw size={14}/> {busy?'Guardando…':'Volver a incluir'}</button>
  </div>
  return <div className={`entry-review-control ${mobile?'mobile':''}`}>
    <button type="button" disabled={busy} className="entry-review-button exclude" onClick={()=>onChange?.(item,true)}><X size={14}/> {busy?'Guardando…':'Quitar del cálculo'}</button>
  </div>
}

function SupportCell({item,onOpen}){
  if(item.entry_type==='credit') return <span className="support-empty">—</span>

  const kind=supportKind(item)
  const shown=isShown(item)

  if(kind==='receipt') return <div className="support-compact receipt-only">
    {canOpenReceipt(item)
      ? <button className="support-link receipt" onClick={()=>onOpen('receipt')}><Eye size={15}/> Ver boleta</button>
      : shown
        ? <span className="support-text receipt"><CheckCircle2 size={14}/> Boleta mostrada</span>
        : <span className="support-text receipt"><FileText size={14}/> Boleta registrada</span>}
    <span className={`support-status ${item.receipt_delivered?'delivered':'pending'}`}>
      {item.receipt_delivered?<CheckCircle2 size={13}/>:<CircleAlert size={13}/>}
      {item.receipt_delivered?'Entregada':'Pendiente'}
    </span>
  </div>

  if(kind==='declaration') return <div className="support-compact declaration-only">
    <button className="support-link declaration" onClick={()=>onOpen('declaration')}><FileText size={15}/> Ver declaración jurada</button>
  </div>

  if(kind==='lost') return <div className="support-compact">
    <span className="support-text lost"><AlertTriangle size={14}/> Boleta extraviada</span>
  </div>

  return <span className="support-empty">Sin sustento</span>
}

function ReviewPanel({bundle,onReview}){
  const {report}=bundle
  const [note,setNote]=useState(report.boss_note||'')
  const [reviewedBy,setReviewedBy]=useState(report.reviewed_by||'Luis Guillermo Muñoz Quijandría')
  useEffect(()=>{setNote(report.boss_note||'');setReviewedBy(report.reviewed_by||'Luis Guillermo Muñoz Quijandría')},[report.id,report.status,report.boss_note,report.reviewed_by])
  const status=statusMeta[report.status]||[report.status,'neutral']
  return <section className="review-shell">
    <details className="review-details">
      <summary className="review-summary">
        <div className="review-summary-icon"><MessageSquareText size={19}/></div>
        <div className="review-summary-copy">
          <span className="eyebrow">{report.period_end?'REVISIÓN DEL PERÍODO':'REVISIÓN DEL REPORTE ACTUAL'}</span>
          <strong>Conformidad del administrador</strong>
          <small>Despliega solo si necesitas aprobar, pedir corrección o volver a revisión.</small>
        </div>
        <span className={`status ${status[1]}`}>{status[0]}</span>
        <ChevronDown className="review-chevron" size={20}/>
      </summary>
      <div className="review-body">
        <div className={`review-state ${status[1]}`}><div><strong>{status[0]}</strong>{report.reviewed_at&&<span>{report.reviewed_by||'Administrador'} · {new Date(report.reviewed_at).toLocaleString('es-PE')}</span>}</div></div>
        {report.status==='draft' ? <div className="review-info">El reporte todavía está en preparación desde la APK. Cuando sea enviado para revisión aparecerán los controles de aprobación.</div> : <>
          <div className="review-grid"><div><label>Administrador</label><input value={reviewedBy} onChange={e=>setReviewedBy(e.target.value)}/></div><div><label>Observación</label><textarea value={note} onChange={e=>setNote(e.target.value)} placeholder="Opcional: escribe una observación breve"/></div></div>
          <div className="review-actions">
            {report.status==='submitted' && <><button className="approve" onClick={()=>onReview(report.id,'approve',note,reviewedBy)}><CheckCircle2 size={17}/> Aprobar reporte</button><button className="correction" onClick={()=>onReview(report.id,'correction',note,reviewedBy)}><CircleAlert size={17}/> Solicitar corrección</button></>}
            {(report.status==='approved'||report.status==='correction_requested') && <button className="reset-review" onClick={()=>onReview(report.id,'reset','',reviewedBy)}><RotateCcw size={17}/> Volver a revisión</button>}
          </div>
        </>}
      </div>
    </details>
  </section>
}

function EvidenceModal({item,kind="receipt",report,onClose}){
  const declaration=kind==='declaration'
  const src=declaration
    ? (item.support_asset && item.support_type?.includes('declaration') ? asset(item.support_asset) : null)
    : (item.receipt_image_base64 ? `data:${item.receipt_mime||'image/jpeg'};base64,${item.receipt_image_base64}` : (item.support_asset && !item.support_type?.includes('declaration') ? asset(item.support_asset) : null))
  return <div className="modal-backdrop" onClick={onClose}><div className="modal" onClick={e=>e.stopPropagation()}><button className="modal-close" onClick={onClose}><X size={19}/></button>
    <div className="modal-heading"><div><span>{declaration?'Declaración jurada':'Evidencia de boleta'}</span><strong>{formatDate(item.entry_date)} · {money(item.amount)} · {movementDetail(item)}</strong>{!declaration && hasReceipt(item)&&<small className={`modal-delivery ${item.receipt_delivered?'delivered':'pending'}`}>{item.receipt_delivered?'BOLETA ENTREGADA AL ADMINISTRADOR':'BOLETA PENDIENTE DE ENTREGAR'}</small>}</div></div>
    {declaration
      ? (src ? <img className="receipt-image document-image" src={src}/> : <DeclarationCard item={item} report={report}/>)
      : (src ? <img className="receipt-image" src={src}/> : <div className="empty-support">La boleta no está guardada digitalmente.</div>)}
  </div></div>
}

function DeclarationCard({item,report}){
  return <article className="declaration-card">
    <header className="dj-header">
      <ApcLogo className="dj-logo"/>
      <div className="dj-header-copy">
        <span>APC CORPORACION S.A.</span>
        <h2>DECLARACIÓN JURADA DE GASTO DE TRANSPORTE</h2>
        <p>Sustento de movilidad sin emisión de comprobante</p>
      </div>
    </header>

    <div className="dj-reference">
      <div><span>Trabajador</span><strong>{report.owner_name}</strong><small>DNI {report.owner_dni}</small></div>
      <div><span>Empresa</span><strong>{report.company_name}</strong><small>RUC {report.company_ruc}</small></div>
    </div>

    <section className="dj-block">
      <div className="dj-block-title">DATOS DEL GASTO</div>
      <div className="dj-grid">
        <Data label="Fecha del pasaje" value={formatDate(item.entry_date)}/>
        <Data label="Monto pagado" value={money(item.amount)} accent/>
        <Data label="Origen" value={item.origin||'—'}/>
        <Data label="Destino" value={item.destination||'—'}/>
        <Data label="Ingeniero responsable" value={item.engineer_name||report.engineer_name||'—'}/>
        <Data label="Motivo" value={cleanText(item.declaration_reason)||'Servicio de transporte sin emisión de comprobante'}/>
      </div>
    </section>

    <section className="dj-block">
      <div className="dj-block-title declaration-title">DECLARACIÓN</div>
      <div className="dj-statement">
        <p>{declarationText(item,report)}</p>
      </div>
    </section>

    <div className="dj-place">
      <span>Lugar y fecha de firma</span>
      <strong>{cleanText(item.declaration_place_date)||'—'}</strong>
    </div>

    <div className="signatures">
      <div className="signature-box">
        <div className="signature-visual">{item.signature_base64?<img src={`data:image/png;base64,${item.signature_base64}`}/>:<span/>}</div>
        <div className="sign-line">FIRMA DEL TRABAJADOR</div>
        <strong>{report.owner_name}</strong>
        <small>DNI {report.owner_dni}</small>
      </div>
      <div className="signature-box">
        <div className="signature-visual"><span/></div>
        <div className="sign-line">V.º B.º / FIRMA DEL ADMINISTRADOR</div>
        <strong>{item.engineer_name||report.engineer_name||'Administrador'}</strong>
        <small>Conformidad del gasto</small>
      </div>
    </div>

    <footer className="dj-footer">Documento de sustento interno de transporte · APC Corporacion</footer>
  </article>
}

function Data({label,value,accent}) {return <div className="data-cell"><span>{label}</span><strong className={accent?'accent':''}>{value}</strong></div>}
function declarationText(e,r){return `Yo, ${r.owner_name}, identificado con DNI N.° ${r.owner_dni}, declaro bajo juramento que el día ${formatDate(e.entry_date)} realicé un gasto de ${money(e.amount)} por concepto de transporte en la ruta ${movementDetail(e)}, relacionado con mis traslados laborales para ${r.company_name}, RUC ${r.company_ruc}. El transportista no emitió boleta, factura ni otro comprobante de pago por el servicio. El motivo del uso de este transporte fue: ${cleanText(e.declaration_reason)||'falta de disponibilidad de transporte público regular'}. Declaro que la información consignada es verdadera y autorizo su uso como sustento interno del gasto de transporte.`}

async function urlToDataUrl(url){
  const res=await fetch(url);if(!res.ok)throw new Error('No se pudo cargar la evidencia')
  const blob=await res.blob();return await new Promise((resolve,reject)=>{const fr=new FileReader();fr.onload=()=>resolve(fr.result);fr.onerror=reject;fr.readAsDataURL(blob)})
}
async function entryImageData(e){
  if(e.receipt_image_base64)return `data:${e.receipt_mime||'image/jpeg'};base64,${e.receipt_image_base64}`
  if(e.support_asset)return await urlToDataUrl(asset(e.support_asset))
  return null
}
function periodTitle(b){const r=b.report;return r.period_end?`${formatDate(r.period_start)} – ${formatDate(r.period_end)}`:`Desde ${formatDate(r.period_start)}`}

async function downloadAllPdf(bundles){
  const [{ jsPDF }, autoTableMod] = await Promise.all([import('jspdf'), import('jspdf-autotable')])
  const autoTable = autoTableMod.default || autoTableMod.autoTable
  const doc=new jsPDF({unit:'mm',format:'a4'});const navy=[23,50,77],green=[25,133,111],orange=[239,125,32];let first=true
  for(const b of bundles){
    if(!first)doc.addPage();first=false
    const {report:r,summary:s,entries=[]}=b;const raw=Number(s.raw_balance??(s.received-s.spent))
    doc.setFillColor(...navy);doc.rect(12,12,186,18,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(14);doc.text(r.is_closed?'CUENTA DE TRANSPORTE LIQUIDADA':r.period_end?'REPORTE DE TRANSPORTE ENVIADO':'REPORTE DE TRANSPORTE ACTUAL',105,23,{align:'center'})
    doc.setTextColor(31,41,55);doc.setFontSize(9);doc.text(`${r.owner_name} · DNI ${r.owner_dni} · APC CORPORACION S.A.`,12,38);doc.text(periodTitle(b),12,44)
    const labels=['RECIBIDO','GASTADO',r.is_closed?'AJUSTE DE CIERRE':'SALDO'];const vals=[money(s.received),money(s.spent),money(r.is_closed?Math.abs(raw):s.balance)]
    labels.forEach((x,i)=>{const x0=12+i*62;doc.setFillColor(233,243,250);doc.roundedRect(x0,50,58,21,3,3,'F');doc.setTextColor(70,85,96);doc.setFontSize(7);doc.text(x,x0+4,57);doc.setFontSize(13);doc.setFont('helvetica','bold');doc.setTextColor(...(i===0?green:i===1?orange:navy));doc.text(vals[i],x0+4,67)})
    if(r.is_closed){doc.setTextColor(...green);doc.setFontSize(8);doc.text(`CUENTA LIQUIDADA · Saldo pendiente actual: S/ 0.00`,12,78)}
    autoTable(doc,{startY:r.is_closed?83:78,head:[['Fecha','Tipo','Detalle','Monto','Sustento','Cálculo']],body:entries.map(e=>[formatDate(e.entry_date),e.entry_type==='credit'?'Crédito':'Gasto',movementDetail(e)+(cleanText(e.issue_time)?` · ${cleanText(e.issue_time)}`:''),(e.entry_type==='credit'?'+':'−')+money(e.amount),supportExportLabel(e),isExcluded(e)?'Fuera del cálculo':'Incluido']),headStyles:{fillColor:navy},styles:{fontSize:6.7,cellPadding:1.8},columnStyles:{3:{halign:'right'},5:{cellWidth:24}}})
  }
  for(const b of bundles){
    for(const e of b.entries.filter(v=>v.entry_type==='expense'&&canOpenSupport(v))){
      const kind=supportKind(e);const data=await entryImageData(e).catch(()=>null);if(!data && kind==='declaration'){addDeclarationPdf(doc,e,b.report,autoTable);continue}if(!data)continue
      doc.addPage();doc.setFillColor(...green);doc.rect(12,12,186,10,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(10);doc.text(`${kind==='declaration'?'DECLARACIÓN JURADA':'EVIDENCIA DE BOLETA'} · ${formatDate(e.entry_date)} · ${money(e.amount)}${kind==='receipt'?` · ${receiptDeliveryText(e).toUpperCase()}`:''}`,105,19,{align:'center'})
      try{const props=doc.getImageProperties(data);const maxW=174,maxH=250;const sc=Math.min(maxW/props.width,maxH/props.height);const w=props.width*sc,h=props.height*sc;doc.addImage(data,props.fileType||'JPEG',18+(174-w)/2,30,w,h)}catch{}
    }
  }
  doc.save('APC_Transporte_Consolidado.pdf')
}
function addDeclarationPdf(doc,e,r,autoTable){
  doc.addPage()
  const navy=[23,50,77],green=[25,133,111],orange=[239,125,32],line=[216,226,231],soft=[247,250,251]
  doc.setFillColor(...navy);doc.roundedRect(12,12,186,22,2,2,'F')
  doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(13);doc.text('DECLARACIÓN JURADA DE GASTO DE TRANSPORTE',105,22,{align:'center'})
  doc.setFont('helvetica','normal');doc.setFontSize(7.5);doc.text('APC CORPORACION S.A. · Sustento interno de movilidad',105,29,{align:'center'})
  doc.setTextColor(...navy);doc.setFont('helvetica','bold');doc.setFontSize(8)
  doc.text(`${r.owner_name} · DNI ${r.owner_dni}`,14,42)
  doc.text(`${r.company_name} · RUC ${r.company_ruc}`,196,42,{align:'right'})
  doc.setFillColor(...green);doc.rect(12,48,186,8,'F');doc.setTextColor(255);doc.text('DATOS DEL GASTO',105,53.5,{align:'center'})
  autoTable(doc,{
    startY:56,
    body:[
      ['Fecha del pasaje',formatDate(e.entry_date),'Monto pagado',money(e.amount)],
      ['Origen',e.origin||'—','Destino',e.destination||'—'],
      ['Ingeniero responsable',e.engineer_name||r.engineer_name||'—','Motivo',cleanText(e.declaration_reason)||'Servicio sin emisión de comprobante']
    ],
    theme:'grid',
    styles:{fontSize:8,cellPadding:3,lineColor:line,lineWidth:.2,valign:'middle'},
    columnStyles:{0:{fillColor:soft,fontStyle:'bold',cellWidth:35},1:{cellWidth:58},2:{fillColor:soft,fontStyle:'bold',cellWidth:35},3:{cellWidth:58}},
    didParseCell(data){if(data.row.index===0&&data.column.index===3){data.cell.styles.textColor=green;data.cell.styles.fontStyle='bold'}}
  })
  let y=doc.lastAutoTable.finalY+8
  doc.setFillColor(...green);doc.rect(12,y,186,8,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(8);doc.text('DECLARACIÓN',105,y+5.5,{align:'center'})
  y+=13
  doc.setTextColor(31,41,55);doc.setFont('helvetica','normal');doc.setFontSize(9)
  const lines=doc.splitTextToSize(declarationText(e,r),176);doc.text(lines,17,y,{maxWidth:176,lineHeightFactor:1.45})
  y+=lines.length*5.1+7
  doc.setFillColor(255,248,225);doc.setDrawColor(235,215,160);doc.roundedRect(16,y,178,13,2,2,'FD')
  doc.setTextColor(85,67,28);doc.setFont('helvetica','bold');doc.setFontSize(8);doc.text('Lugar y fecha de firma',20,y+5)
  doc.setFont('helvetica','normal');doc.text(cleanText(e.declaration_place_date)||'—',20,y+10)
  y+=24
  doc.setDrawColor(70,85,96);doc.line(24,y+20,88,y+20);doc.line(122,y+20,186,y+20)
  if(e.signature_base64){try{doc.addImage(`data:image/png;base64,${e.signature_base64}`,'PNG',37,y-4,38,22)}catch{}}
  doc.setTextColor(...navy);doc.setFont('helvetica','bold');doc.setFontSize(7.5);doc.text('FIRMA DEL TRABAJADOR',56,y+25,{align:'center'});doc.text('V.º B.º / FIRMA DEL ADMINISTRADOR',154,y+25,{align:'center'})
  doc.setFont('helvetica','normal');doc.setFontSize(7);doc.text(r.owner_name,56,y+30,{align:'center'});doc.text(e.engineer_name||r.engineer_name||'Administrador',154,y+30,{align:'center'})
}


async function downloadAllExcel(bundles){
  const [excelMod, saverMod] = await Promise.all([import('exceljs'), import('file-saver')])
  const ExcelJS = excelMod.default || excelMod
  const saveAs = saverMod.saveAs || saverMod.default
  const wb=new ExcelJS.Workbook();wb.creator='APC Corporacion';const ws=wb.addWorksheet('Reporte',{views:[{showGridLines:false}]});ws.columns=[{width:15},{width:14},{width:38},{width:16},{width:23},{width:20}]
  const border={top:{style:'thin',color:{argb:'FFC7D0D8'}},bottom:{style:'thin',color:{argb:'FFC7D0D8'}},left:{style:'thin',color:{argb:'FFC7D0D8'}},right:{style:'thin',color:{argb:'FFC7D0D8'}}};let row=1
  for(const b of bundles){const r=b.report,s=b.summary,entries=b.entries||[],raw=Number(s.raw_balance??(s.received-s.spent));ws.mergeCells(row,1,row,6);let c=ws.getCell(row,1);c.value=r.is_closed?`CUENTA LIQUIDADA · ${periodTitle(b)}`:r.period_end?`REPORTE ENVIADO · ${periodTitle(b)}`:`REPORTE ACTUAL · ${periodTitle(b)}`;c.font={bold:true,color:{argb:'FFFFFFFF'},size:14};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF17324D'}};c.alignment={horizontal:'center'};row++
    ws.getRow(row).values=['Recibido',Number(s.received),'Gastado',Number(s.spent),r.is_closed?`Saldo liquidado S/ 0.00`:`Saldo ${money(s.balance)}`,''];ws.getRow(row).eachCell(x=>{x.border=border;x.alignment={vertical:'middle'}});ws.getCell(row,2).numFmt='"S/ "#,##0.00';ws.getCell(row,4).numFmt='"S/ "#,##0.00';row++
    if(r.is_closed){ws.mergeCells(row,1,row,6);ws.getCell(row,1).value=(raw>0?`Devolución al cierre: ${money(Math.abs(raw))}`:raw<0?`Regularización al cierre: ${money(Math.abs(raw))}`:'Sin ajuste de cierre')+' · Cuenta liquidada';ws.getCell(row,1).font={bold:true,color:{argb:'FF116B5A'}};row++}
    const head=ws.getRow(row);head.values=['Fecha','Tipo','Detalle','Monto','Sustento','Cálculo'];head.eachCell(x=>{x.font={bold:true,color:{argb:'FFFFFFFF'}};x.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF17324D'}};x.border=border;x.alignment={horizontal:'center'}});row++
    entries.forEach(e=>{const rr=ws.getRow(row);rr.values=[formatDate(e.entry_date),e.entry_type==='credit'?'CRÉDITO':'GASTO',movementDetail(e)+(cleanText(e.issue_time)?` · Hora ${cleanText(e.issue_time)}`:''),Number(e.amount),supportExportLabel(e).toUpperCase(),isExcluded(e)?'FUERA DEL CÁLCULO':'INCLUIDO'];rr.eachCell(x=>{x.border=border;x.alignment={vertical:'middle',wrapText:true}});rr.getCell(4).numFmt='"S/ "#,##0.00';row++});row+=2}
  const ev=wb.addWorksheet('Evidencias',{views:[{showGridLines:false}]});ev.columns=Array.from({length:8},()=>({width:15}));let er=1
  for(const b of bundles){for(const e of b.entries.filter(v=>v.entry_type==='expense'&&canOpenSupport(v))){const kind=supportKind(e);const data=await entryImageData(e).catch(()=>null);ev.mergeCells(er,1,er,8);let c=ev.getCell(er,1);c.value=`${kind==='declaration'?'DECLARACIÓN JURADA':'BOLETA'} · ${formatDate(e.entry_date)} · ${money(e.amount)} · ${movementDetail(e)}${kind==='receipt'?` · ${receiptDeliveryText(e).toUpperCase()}`:''}`;c.font={bold:true,color:{argb:'FFFFFFFF'}};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:kind==='declaration'?'FF17324D':'FF19856F'}};c.alignment={horizontal:'center'};er++
      if(data){try{const m=String(data).match(/^data:image\/(png|jpeg|jpg);base64,(.*)$/i);if(m){const id=wb.addImage({base64:m[2],extension:m[1].toLowerCase()==='png'?'png':'jpeg'});ev.addImage(id,{tl:{col:1,row:er-1},ext:{width:430,height:570}});er+=31}}catch{er+=2}}else{ev.mergeCells(er,1,er+4,8);ev.getCell(er,1).value=declarationText(e,b.report);ev.getCell(er,1).alignment={wrapText:true,vertical:'middle'};er+=6}er+=2}}
  const buffer=await wb.xlsx.writeBuffer();saveAs(new Blob([buffer],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}),'APC_Transporte_Consolidado.xlsx')
}

function Empty(){return <div className="empty"><FileText size={42}/><h2>Aún no hay reportes</h2><p>Cuando sincronices desde la APK aparecerán aquí.</p></div>}
createRoot(document.getElementById('root')).render(<App/>)
