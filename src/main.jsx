import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  AlertTriangle, CheckCircle2, CircleAlert, Download, Eye, FileSpreadsheet, FileText,
  LogOut, MessageSquareText, Moon, RefreshCw, RotateCcw, ShieldCheck, Sun, X
} from 'lucide-react'
import { saveAs } from 'file-saver'
import ExcelJS from 'exceljs'
import jsPDF from 'jspdf'
import autoTable from 'jspdf-autotable'
import { getReport, listReports, login, reviewReport } from './supabase'
import './styles.css'

const asset = name => `${import.meta.env.BASE_URL}${name}`
const money = n => `S/ ${Number(n || 0).toLocaleString('es-PE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
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
const canOpenSupport = e => !!(e.receipt_image_base64 || e.support_asset || e.support_type?.includes('declaration'))

function App(){
  const [pin,setPin] = useState(sessionStorage.getItem('apc_pin') || '')
  const [logged,setLogged] = useState(false)
  const [bundles,setBundles] = useState([])
  const [loading,setLoading] = useState(false)
  const [error,setError] = useState('')
  const [modal,setModal] = useState(null)
  const [theme,setTheme] = useState(localStorage.getItem('apc_theme') || 'light')

  useEffect(()=>{document.documentElement.dataset.theme=theme;localStorage.setItem('apc_theme',theme)},[theme])
  useEffect(()=>{ if(pin && sessionStorage.getItem('apc_pin')) doLogin(pin, true) },[])

  const current = useMemo(()=>bundles.find(b=>!b.report?.is_closed && !b.report?.period_end) || null,[bundles])
  const pending = useMemo(()=>bundles.filter(b=>!b.report?.is_closed && !!b.report?.period_end).sort((a,b)=>String(b.report.period_start).localeCompare(String(a.report.period_start))),[bundles])
  const closed = useMemo(()=>bundles.filter(b=>b.report?.is_closed).sort((a,b)=>String(b.report.period_start).localeCompare(String(a.report.period_start))),[bundles])

  async function doLogin(value=pin, quiet=false){
    setLoading(true); setError('')
    try{
      const r = await login(value)
      if(!r?.ok) throw new Error('PIN incorrecto')
      sessionStorage.setItem('apc_pin',value); setPin(value); setLogged(true)
      await refreshAll(value)
    }catch(e){ if(!quiet) setError(e.message || 'No se pudo ingresar') }
    finally{setLoading(false)}
  }
  async function refreshAll(p=pin){
    setLoading(true);setError('')
    try{
      const rows=await listReports(p)
      const loaded=await Promise.all((rows||[]).map(r=>getReport(p,r.id)))
      loaded.sort((a,b)=>{
        if(!!a.report.is_closed!==!!b.report.is_closed) return a.report.is_closed?1:-1
        return String(b.report.period_start).localeCompare(String(a.report.period_start))
      })
      setBundles(loaded)
    }catch(e){setError(e.message||'No se pudo actualizar la web')}
    finally{setLoading(false)}
  }
  async function review(reportId,action,note,reviewedBy){
    if(!reportId) return
    setLoading(true);setError('')
    try{await reviewReport(pin,reportId,action,note,reviewedBy);await refreshAll()}
    catch(e){setError(e.message||'No se pudo guardar la revisión')}
    finally{setLoading(false)}
  }
  function logout(){sessionStorage.removeItem('apc_pin');setLogged(false);setBundles([]);setPin('')}

  if(!logged) return <Login pin={pin} setPin={setPin} onLogin={()=>doLogin()} loading={loading} error={error} theme={theme} setTheme={setTheme}/>
  return <div className="app-shell">
    <header className="topbar">
      <div className="brand"><img src={asset('apc-logo.jpg')}/><div><strong>APC Corporacion</strong><span>Control de transporte</span></div></div>
      <div className="top-actions">
        <button className="icon-btn" onClick={()=>setTheme(theme==='dark'?'light':'dark')} title="Cambiar modo">{theme==='dark'?<Sun size={19}/>:<Moon size={19}/>}</button>
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

        {current && <>
          <div className="section-marker current-marker"><span>PERÍODO ACTUAL</span><b>Cuenta abierta</b></div>
          <PeriodSection bundle={current} current onEvidence={(item)=>setModal({item,report:current.report})}/>
          {current.report.status!=='draft' && <ReviewPanel bundle={current} onReview={review}/>} 
        </>}

        {!!pending.length && <div className="past-title"><span className="eyebrow">ENVIADOS</span><h2>Pendientes de revisión o liquidación</h2><p>Estos periodos ya terminaron, pero todavía no se han marcado como cuentas liquidadas desde la APK.</p></div>}
        {pending.map(b=><React.Fragment key={b.report.id}>
          <div className="section-marker pending-marker"><span>{formatDate(b.report.period_start)} – {formatDate(b.report.period_end)}</span><b>{statusMeta[b.report.status]?.[0]||'En revisión'}</b></div>
          <PeriodSection bundle={b} pending onEvidence={(item)=>setModal({item,report:b.report})}/>
          <ReviewPanel bundle={b} onReview={review}/>
        </React.Fragment>)}

        {!!closed.length && <div className="past-title"><span className="eyebrow">CUENTAS ANTERIORES</span><h2>Períodos liquidados</h2><p>Estos períodos quedaron saldados al finalizar. Su saldo pendiente actual es S/ 0.00.</p></div>}
        {closed.map(b=><React.Fragment key={b.report.id}>
          <div className="section-marker closed-marker"><span>{formatDate(b.report.period_start)} – {formatDate(b.report.period_end)}</span><b><CheckCircle2 size={15}/> Liquidado</b></div>
          <PeriodSection bundle={b} onEvidence={(item)=>setModal({item,report:b.report})}/>
        </React.Fragment>)}
      </>}
    </main>
    {modal && <EvidenceModal item={modal.item} report={modal.report} onClose={()=>setModal(null)}/>} 
  </div>
}

function Login({pin,setPin,onLogin,loading,error,theme,setTheme}){
  return <div className="login-page"><button className="login-theme" onClick={()=>setTheme(theme==='dark'?'light':'dark')}>{theme==='dark'?<Sun size={19}/>:<Moon size={19}/>}</button><div className="login-card">
    <img className="login-logo" src={asset('apc-logo.jpg')}/><div className="login-icon"><ShieldCheck size={28}/></div>
    <h1>Reporte de transporte</h1><p>Consulta el reporte actual, las cuentas liquidadas, boletas y declaraciones juradas.</p>
    <label>PIN de acceso</label><input autoFocus inputMode="numeric" value={pin} onChange={e=>setPin(e.target.value)} onKeyDown={e=>e.key==='Enter'&&onLogin()} placeholder="Ingresa el PIN"/>
    {error&&<div className="field-error">{error}</div>}
    <button className="primary wide" onClick={onLogin} disabled={loading||!pin}>{loading?'Ingresando…':'Ver reporte'}</button>
  </div></div>
}

function PeriodSection({bundle,current=false,pending=false,onEvidence}){
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
    <div className="table-wrap"><table><thead><tr><th>Fecha</th><th>Tipo</th><th>Detalle</th><th className="right">Monto</th><th>Sustento</th></tr></thead><tbody>
      {entries.map(e=><tr key={e.id}>
        <td data-label="Fecha">{formatDate(e.entry_date)}</td>
        <td data-label="Tipo"><span className={`type-pill ${e.entry_type}`}>{e.entry_type==='credit'?'Crédito':'Gasto'}</span></td>
        <td data-label="Detalle"><strong className="mobile-detail">{movementDetail(e)}</strong>{e.issue_time&&<span className="subline">Hora: {e.issue_time}</span>}</td>
        <td data-label="Monto" className={`right amount ${e.entry_type}`}>{e.entry_type==='credit'?'+':'−'}{money(e.amount)}</td>
        <td data-label="Sustento"><SupportCell item={e} onOpen={()=>onEvidence(e)}/></td>
      </tr>)}
    </tbody></table></div>
  </section>
}

function SupportCell({item,onOpen}){
  if(item.entry_type==='credit') return <span className="muted">—</span>
  if(isLost(item)) return <span className="lost-badge"><AlertTriangle size={15}/> Boleta extraviada</span>
  if(isShown(item) && !canOpenSupport(item)) return <span className="shown-badge"><CheckCircle2 size={15}/> Ya mostrada</span>
  if(canOpenSupport(item)) return <button className={`support-btn ${item.support_type?.includes('declaration')?'declaration':''}`} onClick={onOpen}><Eye size={16}/>{item.support_type?.includes('declaration')?'Ver declaración':'Ver boleta'}</button>
  return <span className="muted">Sin sustento</span>
}

function ReviewPanel({bundle,onReview}){
  const {report}=bundle
  const [note,setNote]=useState(report.boss_note||'')
  const [reviewedBy,setReviewedBy]=useState(report.reviewed_by||'Luis Guillermo Muñoz Quijandría')
  useEffect(()=>{setNote(report.boss_note||'');setReviewedBy(report.reviewed_by||'Luis Guillermo Muñoz Quijandría')},[report.id,report.status,report.boss_note,report.reviewed_by])
  const status=statusMeta[report.status]||[report.status,'neutral']
  return <section className="panel review-panel">
    <div className="panel-title"><div><span className="eyebrow">{report.period_end?'REVISIÓN DEL PERÍODO ENVIADO':'REVISIÓN DEL REPORTE ACTUAL'}</span><h2>Conformidad del administrador</h2></div><MessageSquareText size={22}/></div>
    <div className={`review-state ${status[1]}`}><div><strong>{status[0]}</strong>{report.reviewed_at&&<span>{report.reviewed_by||'Administrador'} · {new Date(report.reviewed_at).toLocaleString('es-PE')}</span>}</div></div>
    {report.status==='draft' ? <div className="review-info">El reporte todavía está en preparación desde la APK. Cuando sea enviado para revisión aparecerán los botones de aprobación.</div> : <>
      <div className="review-grid"><div><label>Administrador</label><input value={reviewedBy} onChange={e=>setReviewedBy(e.target.value)}/></div><div><label>Observación</label><textarea value={note} onChange={e=>setNote(e.target.value)} placeholder="Opcional: escribe una observación breve"/></div></div>
      <div className="review-actions">
        {report.status==='submitted' && <><button className="approve" onClick={()=>onReview(report.id,'approve',note,reviewedBy)}><CheckCircle2 size={17}/> Aprobar reporte</button><button className="correction" onClick={()=>onReview(report.id,'correction',note,reviewedBy)}><CircleAlert size={17}/> Solicitar corrección</button></>}
        {(report.status==='approved'||report.status==='correction_requested') && <button className="reset-review" onClick={()=>onReview(report.id,'reset','',reviewedBy)}><RotateCcw size={17}/> Volver a revisión</button>}
      </div>
    </>}
  </section>
}

function EvidenceModal({item,report,onClose}){
  const src=item.receipt_image_base64?`data:${item.receipt_mime||'image/jpeg'};base64,${item.receipt_image_base64}`:item.support_asset?asset(item.support_asset):null
  const declaration=item.support_type?.includes('declaration')
  return <div className="modal-backdrop" onClick={onClose}><div className="modal" onClick={e=>e.stopPropagation()}><button className="modal-close" onClick={onClose}><X size={19}/></button>
    <div className="modal-heading"><div><span>{declaration?'Declaración jurada':'Evidencia de boleta'}</span><strong>{formatDate(item.entry_date)} · {money(item.amount)} · {movementDetail(item)}</strong></div></div>
    {src ? <img className={`receipt-image ${declaration?'document-image':''}`} src={src}/> : declaration ? <DeclarationCard item={item} report={report}/> : <div className="empty-support">La evidencia no está guardada digitalmente.</div>}
  </div></div>
}

function DeclarationCard({item,report}){
  return <div className="declaration-card"><div className="dj-title">DECLARACIÓN JURADA DE GASTO DE TRANSPORTE</div><div className="dj-sub">Transporte sin emisión de comprobante</div><div className="dj-ident"><strong>{report.owner_name} · DNI {report.owner_dni}</strong><strong>{report.company_name} · RUC {report.company_ruc}</strong></div><div className="dj-section">DATOS DEL GASTO</div><div className="dj-grid">
    <Data label="Fecha del pasaje" value={formatDate(item.entry_date)}/><Data label="Monto pagado" value={money(item.amount)} accent/><Data label="Origen" value={item.origin||'—'}/><Data label="Destino" value={item.destination||'—'}/><Data label="Ingeniero responsable" value={item.engineer_name||report.engineer_name||'—'}/><Data label="Motivo" value={item.declaration_reason||'Servicio de transporte sin emisión de comprobante'}/>
  </div><div className="dj-section">DECLARACIÓN</div><p className="dj-text">{declarationText(item,report)}</p><div className="dj-place"><b>Lugar y fecha de firma:</b><span>{item.declaration_place_date||'—'}</span></div><div className="signatures"><div>{item.signature_base64?<img src={`data:image/png;base64,${item.signature_base64}`}/>:<div className="sign-space"/>}<div className="sign-line">FIRMA DEL TRABAJADOR</div><span>{report.owner_name}</span><small>DNI {report.owner_dni}</small></div><div><div className="sign-space"/><div className="sign-line">V.º B.º / FIRMA DEL ADMINISTRADOR</div><span>{item.engineer_name||report.engineer_name||''}</span></div></div></div>
}
function Data({label,value,accent}) {return <div className="data-cell"><span>{label}</span><strong className={accent?'accent':''}>{value}</strong></div>}
function declarationText(e,r){return `Yo, ${r.owner_name}, identificado con DNI N.° ${r.owner_dni}, DECLARO BAJO JURAMENTO que el día ${formatDate(e.entry_date)} realicé un gasto de ${money(e.amount)} por concepto de pasaje ${movementDetail(e)}, relacionado con mis traslados laborales para ${r.company_name}, RUC ${r.company_ruc}. El transportista no emitió boleta, factura ni otro comprobante de pago por dicho servicio. Motivo: ${e.declaration_reason||'falta de disponibilidad de transporte público regular'}. Declaro que la información consignada es verdadera y asumo responsabilidad por su contenido para fines de sustento y/o reembolso del gasto de transporte.`}

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
  const doc=new jsPDF({unit:'mm',format:'a4'});const navy=[23,50,77],red=[177,31,23],green=[25,133,111],orange=[239,125,32];let first=true
  for(const b of bundles){
    if(!first)doc.addPage();first=false
    const {report:r,summary:s,entries=[]}=b;const raw=Number(s.raw_balance??(s.received-s.spent))
    doc.setFillColor(...navy);doc.rect(12,12,186,18,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(14);doc.text(r.is_closed?'CUENTA DE TRANSPORTE LIQUIDADA':r.period_end?'REPORTE DE TRANSPORTE ENVIADO':'REPORTE DE TRANSPORTE ACTUAL',105,23,{align:'center'})
    doc.setTextColor(31,41,55);doc.setFontSize(9);doc.text(`${r.owner_name} · DNI ${r.owner_dni} · APC CORPORACION S.A.`,12,38);doc.text(periodTitle(b),12,44)
    const labels=['RECIBIDO','GASTADO',r.is_closed?'AJUSTE DE CIERRE':'SALDO'];const vals=[money(s.received),money(s.spent),money(r.is_closed?Math.abs(raw):s.balance)]
    labels.forEach((x,i)=>{const x0=12+i*62;doc.setFillColor(233,243,250);doc.roundedRect(x0,50,58,21,3,3,'F');doc.setTextColor(70,85,96);doc.setFontSize(7);doc.text(x,x0+4,57);doc.setFontSize(13);doc.setFont('helvetica','bold');doc.setTextColor(...(i===0?green:i===1?orange:navy));doc.text(vals[i],x0+4,67)})
    if(r.is_closed){doc.setTextColor(...green);doc.setFontSize(8);doc.text(`CUENTA LIQUIDADA · Saldo pendiente actual: S/ 0.00`,12,78)}
    autoTable(doc,{startY:r.is_closed?83:78,head:[['Fecha','Tipo','Detalle','Monto','Sustento']],body:entries.map(e=>[formatDate(e.entry_date),e.entry_type==='credit'?'Crédito':'Gasto',movementDetail(e)+(e.issue_time?` · ${e.issue_time}`:''),(e.entry_type==='credit'?'+':'−')+money(e.amount),isLost(e)?'Boleta extraviada':isShown(e)?'Ya mostrada':e.support_type?.includes('declaration')?'Declaración':e.support_type==='receipt'?'Boleta':'—']),headStyles:{fillColor:red},styles:{fontSize:7,cellPadding:2},columnStyles:{3:{halign:'right'}}})
  }
  for(const b of bundles){
    for(const e of b.entries.filter(v=>v.entry_type==='expense'&&canOpenSupport(v))){
      const data=await entryImageData(e).catch(()=>null);if(!data && e.support_type?.includes('declaration')){addDeclarationPdf(doc,e,b.report);continue}if(!data)continue
      doc.addPage();doc.setFillColor(...green);doc.rect(12,12,186,10,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(10);doc.text(`${e.support_type?.includes('declaration')?'DECLARACIÓN JURADA':'EVIDENCIA DE BOLETA'} · ${formatDate(e.entry_date)} · ${money(e.amount)}`,105,19,{align:'center'})
      try{const props=doc.getImageProperties(data);const maxW=174,maxH=250;const sc=Math.min(maxW/props.width,maxH/props.height);const w=props.width*sc,h=props.height*sc;doc.addImage(data,props.fileType||'JPEG',18+(174-w)/2,30,w,h)}catch{}
    }
  }
  doc.save('APC_Transporte_Consolidado.pdf')
}
function addDeclarationPdf(doc,e,r){
  doc.addPage();doc.setFillColor(23,50,77);doc.rect(12,12,186,16,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(12);doc.text('DECLARACIÓN JURADA DE GASTO DE TRANSPORTE',105,22,{align:'center'});doc.setTextColor(31,41,55);doc.setFont('helvetica','normal');doc.setFontSize(9);const lines=doc.splitTextToSize(declarationText(e,r),180);doc.text(lines,15,45)
}

async function downloadAllExcel(bundles){
  const wb=new ExcelJS.Workbook();wb.creator='APC Corporacion';const ws=wb.addWorksheet('Reporte',{views:[{showGridLines:false}]});ws.columns=[{width:15},{width:14},{width:42},{width:16},{width:23}]
  const border={top:{style:'thin',color:{argb:'FFC7D0D8'}},bottom:{style:'thin',color:{argb:'FFC7D0D8'}},left:{style:'thin',color:{argb:'FFC7D0D8'}},right:{style:'thin',color:{argb:'FFC7D0D8'}}};let row=1
  for(const b of bundles){const r=b.report,s=b.summary,entries=b.entries||[],raw=Number(s.raw_balance??(s.received-s.spent));ws.mergeCells(row,1,row,5);let c=ws.getCell(row,1);c.value=r.is_closed?`CUENTA LIQUIDADA · ${periodTitle(b)}`:r.period_end?`REPORTE ENVIADO · ${periodTitle(b)}`:`REPORTE ACTUAL · ${periodTitle(b)}`;c.font={bold:true,color:{argb:'FFFFFFFF'},size:14};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF17324D'}};c.alignment={horizontal:'center'};row++
    ws.getRow(row).values=['Recibido',Number(s.received),'Gastado',Number(s.spent),r.is_closed?`Saldo liquidado S/ 0.00`:`Saldo ${money(s.balance)}`];ws.getRow(row).eachCell(x=>{x.border=border;x.alignment={vertical:'middle'}});ws.getCell(row,2).numFmt='"S/ "#,##0.00';ws.getCell(row,4).numFmt='"S/ "#,##0.00';row++
    if(r.is_closed){ws.mergeCells(row,1,row,5);ws.getCell(row,1).value=(raw>0?`Devolución al cierre: ${money(Math.abs(raw))}`:raw<0?`Regularización al cierre: ${money(Math.abs(raw))}`:'Sin ajuste de cierre')+' · Cuenta liquidada';ws.getCell(row,1).font={bold:true,color:{argb:'FF116B5A'}};row++}
    const head=ws.getRow(row);head.values=['Fecha','Tipo','Detalle','Monto','Sustento'];head.eachCell(x=>{x.font={bold:true,color:{argb:'FFFFFFFF'}};x.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFB11F17'}};x.border=border;x.alignment={horizontal:'center'}});row++
    entries.forEach(e=>{const rr=ws.getRow(row);rr.values=[formatDate(e.entry_date),e.entry_type==='credit'?'CRÉDITO':'GASTO',movementDetail(e)+(e.issue_time?` · Hora ${e.issue_time}`:''),Number(e.amount),isLost(e)?'BOLETA EXTRAVIADA':isShown(e)?'YA MOSTRADA':e.support_type?.includes('declaration')?'DECLARACIÓN JURADA':e.support_type==='receipt'?'BOLETA':'—'];rr.eachCell(x=>{x.border=border;x.alignment={vertical:'middle',wrapText:true}});rr.getCell(4).numFmt='"S/ "#,##0.00';row++});row+=2}
  const ev=wb.addWorksheet('Evidencias',{views:[{showGridLines:false}]});ev.columns=Array.from({length:8},()=>({width:15}));let er=1
  for(const b of bundles){for(const e of b.entries.filter(v=>v.entry_type==='expense'&&canOpenSupport(v))){const data=await entryImageData(e).catch(()=>null);ev.mergeCells(er,1,er,8);let c=ev.getCell(er,1);c.value=`${e.support_type?.includes('declaration')?'DECLARACIÓN JURADA':'BOLETA'} · ${formatDate(e.entry_date)} · ${money(e.amount)} · ${movementDetail(e)}`;c.font={bold:true,color:{argb:'FFFFFFFF'}};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:e.support_type?.includes('declaration')?'FF17324D':'FF19856F'}};c.alignment={horizontal:'center'};er++
      if(data){try{const m=String(data).match(/^data:image\/(png|jpeg|jpg);base64,(.*)$/i);if(m){const id=wb.addImage({base64:m[2],extension:m[1].toLowerCase()==='png'?'png':'jpeg'});ev.addImage(id,{tl:{col:1,row:er-1},ext:{width:430,height:570}});er+=31}}catch{er+=2}}else{ev.mergeCells(er,1,er+4,8);ev.getCell(er,1).value=declarationText(e,b.report);ev.getCell(er,1).alignment={wrapText:true,vertical:'middle'};er+=6}er+=2}}
  const buffer=await wb.xlsx.writeBuffer();saveAs(new Blob([buffer],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}),'APC_Transporte_Consolidado.xlsx')
}

function Empty(){return <div className="empty"><FileText size={42}/><h2>Aún no hay reportes</h2><p>Cuando sincronices desde la APK aparecerán aquí.</p></div>}
createRoot(document.getElementById('root')).render(<App/>)
