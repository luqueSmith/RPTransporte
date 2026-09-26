import React, { useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  CheckCircle2, ChevronDown, ChevronRight, CircleAlert, Clock3, Download,
  Eye, FileImage, FileSpreadsheet, FileText, LogOut, MessageSquareText,
  RefreshCw, Route, ShieldCheck, WalletCards, X, XCircle
} from 'lucide-react'
import { saveAs } from 'file-saver'
import ExcelJS from 'exceljs'
import jsPDF from 'jspdf'
import autoTable from 'jspdf-autotable'
import { getReport, listReports, login, reviewReport } from './supabase'
import './styles.css'

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
  draft: ['En preparación','neutral'], submitted: ['Enviado para revisión','info'],
  approved: ['Aprobado','ok'], correction_requested: ['Requiere corrección','warn']
}
const supportLabel = e => e.support_type === 'receipt' ? 'Ver boleta' : e.support_type === 'declaration' ? 'Ver declaración' : e.support_type === 'receipt_declaration' ? 'Ver sustento' : 'Sin sustento'

function App(){
  const [pin,setPin] = useState(sessionStorage.getItem('apc_pin') || '')
  const [logged,setLogged] = useState(false)
  const [profile,setProfile] = useState(null)
  const [reports,setReports] = useState([])
  const [selectedId,setSelectedId] = useState(null)
  const [bundle,setBundle] = useState(null)
  const [loading,setLoading] = useState(false)
  const [error,setError] = useState('')
  const [modal,setModal] = useState(null)
  const [note,setNote] = useState('')
  const [reviewedBy,setReviewedBy] = useState('Luis Guillermo Muñoz Quijandría')

  useEffect(()=>{ if(pin && sessionStorage.getItem('apc_pin')) doLogin(pin, true) },[])

  async function doLogin(value=pin, quiet=false){
    setLoading(true); setError('')
    try{
      const r = await login(value)
      if(!r?.ok) throw new Error('PIN incorrecto')
      sessionStorage.setItem('apc_pin',value); setPin(value); setProfile(r); setLogged(true)
      await refreshReports(value)
    }catch(e){ if(!quiet) setError(e.message || 'No se pudo ingresar') }
    finally{setLoading(false)}
  }
  async function refreshReports(p=pin){
    const rows=await listReports(p); setReports(rows)
    const first=rows?.[0]?.id
    if(first){ const target=selectedId && rows.some(r=>r.id===selectedId)?selectedId:first; await selectReport(target,p) }
    else { setBundle(null); setSelectedId(null) }
  }
  async function selectReport(id,p=pin){
    setLoading(true); setError('')
    try{ const b=await getReport(p,id); setSelectedId(id); setBundle(b); setNote(b?.report?.boss_note || '') }
    catch(e){setError(e.message || 'No se pudo abrir el reporte')}
    finally{setLoading(false)}
  }
  async function review(action){
    if(!bundle?.report?.id) return
    setLoading(true);setError('')
    try{await reviewReport(pin,bundle.report.id,action,note,reviewedBy);await refreshReports();}
    catch(e){setError(e.message||'No se pudo guardar la revisión')}
    finally{setLoading(false)}
  }
  function logout(){sessionStorage.removeItem('apc_pin');setLogged(false);setBundle(null);setReports([]);setPin('')}

  if(!logged) return <Login pin={pin} setPin={setPin} onLogin={()=>doLogin()} loading={loading} error={error}/>
  return <div className="app-shell">
    <header className="topbar">
      <div className="brand"><img src="/apc-logo.jpg"/><div><strong>APC Corporacion</strong><span>Reportes de transporte</span></div></div>
      <div className="top-actions"><button className="icon-btn" onClick={()=>refreshReports()} title="Actualizar"><RefreshCw size={19}/></button><button className="ghost" onClick={logout}><LogOut size={17}/> Salir</button></div>
    </header>
    <main className="layout">
      <aside className="history-panel">
        <div className="aside-head"><div><span className="eyebrow">Historial</span><h2>Reportes</h2></div><span className="count">{reports.length}</span></div>
        <div className="history-list">
          {reports.map((r,i)=><button key={r.id} className={`history-item ${selectedId===r.id?'active':''}`} onClick={()=>selectReport(r.id)}>
            <div className="history-icon">{i===0?<Clock3 size={18}/>:<FileText size={18}/>}</div>
            <div className="history-copy"><strong>{formatDate(r.period_start)}{r.period_end?` – ${formatDate(r.period_end)}`:''}</strong><span>{money(r.spent)} gastado · {statusMeta[r.status]?.[0]||r.status}</span></div>
            <ChevronRight size={17}/>
          </button>)}
          {!reports.length && <div className="empty-small">Aún no hay reportes sincronizados desde la APK.</div>}
        </div>
      </aside>
      <section className="content">
        {error && <div className="error-banner"><CircleAlert size={18}/>{error}</div>}
        {loading && <div className="loading-line"><RefreshCw size={16} className="spin"/> Actualizando…</div>}
        {reports.length>0 && <div className="mobile-report-picker"><label>Reporte</label><select value={selectedId||''} onChange={e=>selectReport(e.target.value)}>{reports.map(r=><option key={r.id} value={r.id}>{formatDate(r.period_start)}{r.period_end?` – ${formatDate(r.period_end)}`:''} · {statusMeta[r.status]?.[0]||r.status}</option>)}</select></div>}
        {bundle ? <ReportView bundle={bundle} onEvidence={setModal} note={note} setNote={setNote} reviewedBy={reviewedBy} setReviewedBy={setReviewedBy} onReview={review}/>:<Empty/>}
      </section>
    </main>
    {modal && <EvidenceModal item={modal} report={bundle?.report} onClose={()=>setModal(null)}/>} 
  </div>
}

function Login({pin,setPin,onLogin,loading,error}){
  return <div className="login-page"><div className="login-card">
    <img className="login-logo" src="/apc-logo.jpg"/><div className="login-icon"><ShieldCheck size={28}/></div>
    <h1>Reporte de transporte</h1><p>Acceso sencillo para revisar movimientos, boletas y declaraciones juradas.</p>
    <label>PIN de acceso</label><input autoFocus inputMode="numeric" value={pin} onChange={e=>setPin(e.target.value)} onKeyDown={e=>e.key==='Enter'&&onLogin()} placeholder="Ingresa el PIN"/>
    {error&&<div className="field-error">{error}</div>}
    <button className="primary wide" onClick={onLogin} disabled={loading||!pin}>{loading?'Ingresando…':'Ver reporte'}</button>
    <span className="login-note">No necesitas usuario ni correo.</span>
  </div></div>
}

function ReportView({bundle,onEvidence,note,setNote,reviewedBy,setReviewedBy,onReview}){
  const {report,summary,entries=[]}=bundle
  const status=statusMeta[report.status]||[report.status,'neutral']
  const period=report.period_end?`${longDate(report.period_start)} – ${longDate(report.period_end)}`:`Desde ${longDate(report.period_start)}`
  return <>
    <section className="hero-card">
      <div className="hero-top"><div><span className="eyebrow">Reporte actual</span><h1>{period}</h1><p>{report.owner_name} · DNI {report.owner_dni}</p></div><span className={`status ${status[1]}`}>{status[0]}</span></div>
      <div className="summary-grid">
        <div className="balance-card"><span>Saldo disponible</span><strong>{money(summary.balance)}</strong><small>Recibido menos gastos</small></div>
        <div className="metric"><div className="metric-icon green"><WalletCards size={20}/></div><div><span>Recibido</span><strong>{money(summary.received)}</strong></div></div>
        <div className="metric"><div className="metric-icon orange"><Route size={20}/></div><div><span>Gastado</span><strong>{money(summary.spent)}</strong></div></div>
      </div>
      <div className="download-row"><button className="primary" onClick={()=>downloadPdf(bundle)}><Download size={18}/> Descargar PDF</button><button className="secondary" onClick={()=>downloadExcel(bundle)}><FileSpreadsheet size={18}/> Descargar Excel</button></div>
    </section>

    <section className="panel">
      <div className="panel-title"><div><span className="eyebrow">Detalle</span><h2>Movimientos</h2></div><span className="count">{entries.length}</span></div>
      <div className="table-wrap"><table><thead><tr><th>Fecha</th><th>Tipo</th><th>Detalle</th><th className="right">Monto</th><th>Sustento</th></tr></thead><tbody>
        {entries.map(e=><tr key={e.id}><td data-label="Fecha">{formatDate(e.entry_date)}</td><td data-label="Tipo"><span className={`type-pill ${e.entry_type}`}>{e.entry_type==='credit'?'Crédito':'Gasto'}</span></td><td data-label="Detalle"><strong className="mobile-detail">{movementDetail(e)}</strong>{e.issue_time&&<span className="subline">Hora: {e.issue_time}</span>}</td><td data-label="Monto" className={`right amount ${e.entry_type}`}>{e.entry_type==='credit'?'+':'−'}{money(e.amount)}</td><td data-label="Sustento">{e.entry_type==='credit'?<span className="muted">—</span>:e.support_type==='none'?<span className="muted">Sin sustento</span>:<button className={`support-btn ${e.support_type.includes('declaration')?'declaration':''}`} onClick={()=>onEvidence(e)}><Eye size={16}/>{supportLabel(e)}</button>}</td></tr>)}
      </tbody></table></div>
    </section>

    <section className="panel review-panel">
      <div className="panel-title"><div><span className="eyebrow">Revisión</span><h2>Conformidad del ingeniero</h2></div><MessageSquareText size={22}/></div>
      {report.reviewed_at&&<div className={`review-state ${report.status==='approved'?'approved':'correction'}`}>{report.status==='approved'?<CheckCircle2 size={20}/>:<XCircle size={20}/>}<div><strong>{status[0]}</strong><span>{report.reviewed_by||'Revisado'} · {new Date(report.reviewed_at).toLocaleString('es-PE')}</span></div></div>}
      <div className="review-grid"><div><label>Nombre</label><input value={reviewedBy} onChange={e=>setReviewedBy(e.target.value)}/></div><div className="note-field"><label>Observación (opcional)</label><textarea value={note} onChange={e=>setNote(e.target.value)} placeholder="Ej.: Conforme / Corregir pasaje del 18…"/></div></div>
      <div className="review-actions"><button className="approve" onClick={()=>onReview('approve')}><CheckCircle2 size={18}/> Aprobar reporte</button><button className="correction" onClick={()=>onReview('correction')}><CircleAlert size={18}/> Solicitar corrección</button></div>
    </section>
  </>
}

function EvidenceModal({item,report,onClose}){
  return <div className="modal-backdrop" onClick={onClose}><div className="modal" onClick={e=>e.stopPropagation()}><button className="modal-close" onClick={onClose}><X size={20}/></button>
    {item.receipt_image_base64 && <><div className="modal-heading"><FileImage size={24}/><div><span>Boleta</span><strong>{formatDate(item.entry_date)} · {money(item.amount)}</strong></div></div><img className="receipt-image" src={`data:${item.receipt_mime||'image/jpeg'};base64,${item.receipt_image_base64}`}/></>}
    {item.support_type?.includes('declaration') && <DeclarationCard item={item} report={report}/>} 
  </div></div>
}

function DeclarationCard({item,report}){
  return <article className="declaration-card">
    <div className="dj-title">DECLARACIÓN JURADA DE GASTO DE TRANSPORTE</div>
    <div className="dj-sub">DJ-{formatDate(item.entry_date).replaceAll('/','-')} · Transporte sin emisión de comprobante</div>
    <div className="dj-ident"><strong>{report.owner_name} · DNI {report.owner_dni}</strong><strong>{report.company_name} · RUC {report.company_ruc}</strong></div>
    <div className="dj-section">DATOS DEL GASTO</div>
    <div className="dj-grid">
      <Data label="Fecha del pasaje" value={formatDate(item.entry_date)}/><Data label="Monto pagado" value={money(item.amount)} accent/>
      <Data label="Origen" value={item.origin||'—'}/><Data label="Destino" value={item.destination||'—'}/>
      <Data label="Ingeniero responsable" value={item.engineer_name||report.engineer_name||'—'}/><Data label="Motivo" value={item.declaration_reason||'Servicio de transporte sin emisión de comprobante'}/>
    </div>
    <div className="dj-section">DECLARACIÓN</div>
    <p className="dj-text">{declarationText(item,report)}</p>
    <div className="dj-place"><strong>Lugar y fecha de firma:</strong><span>{item.declaration_place_date||'—'}</span></div>
    <div className="signatures"><div>{item.signature_base64&&<img src={`data:image/png;base64,${item.signature_base64}`}/>}<div className="sign-line">FIRMA DEL TRABAJADOR</div><span>{report.owner_name}</span><small>DNI {report.owner_dni}</small></div><div><div className="sign-space"></div><div className="sign-line">V.º B.º / FIRMA DEL INGENIERO</div><span>{item.engineer_name||report.engineer_name||'Ingeniero responsable'}</span></div></div>
  </article>
}
const Data=({label,value,accent})=><div className="data-cell"><span>{label}</span><strong className={accent?'accent':''}>{value}</strong></div>

function movementDetail(e){
  if(e.entry_type==='credit') return e.detail||'Dinero entregado para movilidad'
  const route=[e.origin,e.destination].filter(Boolean).join(' → ')
  return route || e.detail || 'Pasaje de transporte'
}
function declarationText(e,r){
  const reason=e.declaration_reason?` El motivo del uso de este transporte fue: ${e.declaration_reason}.`:''
  return `Yo, ${r.owner_name}, identificado con DNI N.° ${r.owner_dni}, DECLARO BAJO JURAMENTO que el día ${formatDate(e.entry_date)} realicé un gasto de ${money(e.amount)} por concepto de pasaje de transporte${e.origin||e.destination?` desde ${e.origin||'el punto de origen'} hacia ${e.destination||'el destino indicado'}`:''}, relacionado con mis traslados laborales para ${r.company_name}, RUC ${r.company_ruc}. El transportista no emitió boleta, factura ni otro comprobante de pago por dicho servicio.${reason} Declaro que la información consignada es verdadera y asumo responsabilidad por su contenido para fines de sustento y/o reembolso del gasto de transporte.`
}

async function downloadPdf(bundle){
  const {report,summary,entries=[]}=bundle; const doc=new jsPDF({unit:'mm',format:'a4'}); const W=210; let y=14
  const navy=[23,50,77], red=[175,35,26], green=[25,133,111], orange=[230,126,34], gray=[245,247,250]
  const header=()=>{doc.setFillColor(...navy);doc.roundedRect(12,12,186,20,2,2,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(16);doc.text('REPORTE DE TRANSPORTE',18,22);doc.setFontSize(8.5);doc.setFont('helvetica','normal');doc.text(`${report.company_name} · RUC ${report.company_ruc}`,18,28);doc.setTextColor(31,41,55);doc.setFontSize(9);doc.text(`${report.owner_name} · DNI ${report.owner_dni}`,12,39);y=45}
  header();
  const cards=[['SALDO',summary.balance,navy],['RECIBIDO',summary.received,green],['GASTADO',summary.spent,orange]];cards.forEach((c,i)=>{const x=12+i*63;doc.setFillColor(...gray);doc.roundedRect(x,y,59,20,2,2,'F');doc.setTextColor(...c[2]);doc.setFont('helvetica','bold');doc.setFontSize(8);doc.text(c[0],x+4,y+7);doc.setFontSize(13);doc.text(money(c[1]),x+4,y+15)});y+=27
  doc.setFillColor(...red);doc.rect(12,y,186,9,'F');doc.setTextColor(255);doc.setFontSize(9);doc.text('MOVIMIENTOS',16,y+6);y+=11
  autoTable(doc,{startY:y,margin:{left:12,right:12},head:[['Fecha','Tipo','Detalle','Monto','Sustento']],body:entries.map(e=>[formatDate(e.entry_date),e.entry_type==='credit'?'Crédito':'Gasto',movementDetail(e),`${e.entry_type==='credit'?'+':'−'}${money(e.amount)}`,e.entry_type==='credit'?'—':supportLabel(e)]),styles:{fontSize:8,cellPadding:2.4,valign:'middle'},headStyles:{fillColor:red,textColor:255,fontStyle:'bold'},columnStyles:{3:{halign:'right'}},alternateRowStyles:{fillColor:[249,250,251]}})
  for(const e of entries.filter(x=>x.entry_type==='expense'&&(x.receipt_image_base64||x.support_type?.includes('declaration')))){
    if(e.receipt_image_base64){doc.addPage();doc.setFillColor(...green);doc.rect(12,12,186,10,'F');doc.setTextColor(255);doc.setFontSize(11);doc.setFont('helvetica','bold');doc.text('EVIDENCIA DE BOLETA',16,19);doc.setTextColor(31,41,55);doc.setFontSize(10);doc.text(`${formatDate(e.entry_date)} · ${movementDetail(e)} · ${money(e.amount)}`,12,31);try{const data=`data:${e.receipt_mime||'image/jpeg'};base64,${e.receipt_image_base64}`;const props=doc.getImageProperties(data);const maxW=174,maxH=245;const scale=Math.min(maxW/props.width,maxH/props.height);const w=props.width*scale,h=props.height*scale;doc.addImage(data,props.fileType||'JPEG',18+(174-w)/2,38,w,h)}catch{}}
    if(e.support_type?.includes('declaration')) addDeclarationPdf(doc,e,report)
  }
  doc.save(`Reporte_Transporte_${formatDate(report.period_start).replaceAll('/','-')}.pdf`)
}
function addDeclarationPdf(doc,e,r){
  doc.addPage();const navy=[23,50,77],green=[25,133,111],light=[245,247,250],yellow=[255,244,204];
  doc.setFillColor(...navy);doc.rect(12,12,186,16,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(13);doc.text('DECLARACIÓN JURADA DE GASTO DE TRANSPORTE',105,22,{align:'center'});doc.setTextColor(94,107,120);doc.setFont('helvetica','italic');doc.setFontSize(8.5);doc.text(`DJ-${formatDate(e.entry_date).replaceAll('/','-')} · Transporte sin emisión de comprobante`,105,34,{align:'center'});
  doc.setFont('helvetica','bold');doc.setTextColor(17,107,90);doc.text(`${r.owner_name} · DNI ${r.owner_dni}`,14,44);doc.setTextColor(...navy);doc.text(`${r.company_name} · RUC ${r.company_ruc}`,196,44,{align:'right'});
  doc.setFillColor(...green);doc.rect(12,50,186,9,'F');doc.setTextColor(255);doc.text('DATOS DEL GASTO',105,56,{align:'center'});
  const rows=[['Fecha del pasaje',formatDate(e.entry_date),'Monto pagado',money(e.amount)],['Origen',e.origin||'—','Destino',e.destination||'—'],['Ingeniero responsable',e.engineer_name||r.engineer_name||'—','Motivo',e.declaration_reason||'Servicio sin comprobante']];let y=59;
  rows.forEach((row,idx)=>{doc.setFillColor(...light);doc.rect(12,y,39,13,'F');doc.rect(105,y,39,13,'F');doc.setFillColor(255);doc.rect(51,y,54,13,'F');doc.setFillColor(...(idx===2?yellow:[255,255,255]));doc.rect(144,y,54,13,'F');doc.setTextColor(31,41,55);doc.setFont('helvetica','bold');doc.setFontSize(7.5);doc.text(row[0],14,y+7);doc.text(row[2],107,y+7);doc.setFont('helvetica','normal');doc.text(String(row[1]),53,y+7,{maxWidth:50});doc.text(String(row[3]),146,y+5,{maxWidth:50});y+=13});
  y+=6;doc.setFillColor(...green);doc.rect(12,y,186,9,'F');doc.setTextColor(255);doc.setFont('helvetica','bold');doc.setFontSize(8.5);doc.text('DECLARACIÓN',105,y+6,{align:'center'});y+=14;doc.setTextColor(31,41,55);doc.setFont('helvetica','normal');doc.setFontSize(9);const lines=doc.splitTextToSize(declarationText(e,r),180);doc.text(lines,15,y);y+=lines.length*4.4+9;
  doc.setFillColor(...yellow);doc.rect(12,y,186,10,'F');doc.setFont('helvetica','bold');doc.text('Lugar y fecha de firma:',15,y+6);doc.setFont('helvetica','normal');doc.text(e.declaration_place_date||'—',55,y+6);y+=18;
  if(e.signature_base64){try{doc.addImage(`data:image/png;base64,${e.signature_base64}`,'PNG',29,y,45,18)}catch{}}y+=22;doc.setDrawColor(31,41,55);doc.line(22,y,88,y);doc.line(122,y,188,y);doc.setFont('helvetica','bold');doc.setFontSize(8);doc.text('FIRMA DEL TRABAJADOR',55,y+5,{align:'center'});doc.text('V.º B.º / FIRMA DEL INGENIERO',155,y+5,{align:'center'});doc.setFont('helvetica','normal');doc.text(r.owner_name,55,y+10,{align:'center'});doc.text(e.engineer_name||r.engineer_name||'Ingeniero responsable',155,y+10,{align:'center'});
}

async function downloadExcel(bundle){
  const {report,summary,entries=[]}=bundle;const wb=new ExcelJS.Workbook();wb.creator='APC Corporacion';
  const ws=wb.addWorksheet('Resumen',{views:[{showGridLines:false}]});ws.columns=[{width:16},{width:18},{width:28},{width:28},{width:18}];
  ws.mergeCells('A1:E2');const t=ws.getCell('A1');t.value='REPORTE DE TRANSPORTE';t.font={bold:true,color:{argb:'FFFFFFFF'},size:18};t.alignment={horizontal:'center',vertical:'middle'};t.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF17324D'}};
  ws.mergeCells('A3:E3');ws.getCell('A3').value=`${report.company_name} · RUC ${report.company_ruc}`;ws.getCell('A3').alignment={horizontal:'center'};ws.getCell('A3').font={italic:true,color:{argb:'FF5E6B78'}};
  ws.mergeCells('A5:E5');ws.getCell('A5').value=`${report.owner_name} · DNI ${report.owner_dni}`;ws.getCell('A5').font={bold:true,color:{argb:'FF116B5A'}};
  const sums=[['SALDO',summary.balance,'17324D'],['RECIBIDO',summary.received,'19856F'],['GASTADO',summary.spent,'E67E22']];sums.forEach((s,i)=>{const col=1+i*2;ws.mergeCells(7,col,7,Math.min(col+1,5));const c=ws.getCell(7,col);c.value=`${s[0]}  ${money(s[1])}`;c.font={bold:true,color:{argb:`FF${s[2]}`},size:13};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFF5F7FA'}};c.alignment={horizontal:'center'};});
  ws.addRow([]);const h=ws.addRow(['Fecha','Tipo','Detalle','Monto','Sustento']);h.eachCell(c=>{c.font={bold:true,color:{argb:'FFFFFFFF'}};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFAF231A'}};c.alignment={horizontal:'center'}});
  entries.forEach(e=>{const row=ws.addRow([formatDate(e.entry_date),e.entry_type==='credit'?'Crédito':'Gasto',movementDetail(e),Number(e.amount),e.entry_type==='credit'?'—':supportLabel(e)]);row.getCell(4).numFmt='"S/ "0.00';});
  const ev=wb.addWorksheet('Evidencias y DJ',{views:[{showGridLines:false}]});ev.columns=Array.from({length:8},()=>({width:15}));let row=1;
  for(const e of entries.filter(x=>x.entry_type==='expense'&&(x.receipt_image_base64||x.support_type?.includes('declaration')))){
    if(e.receipt_image_base64){ev.mergeCells(row,1,row,8);let c=ev.getCell(row,1);c.value=`EVIDENCIA · ${formatDate(e.entry_date)} · ${movementDetail(e)} · ${money(e.amount)}`;c.font={bold:true,color:{argb:'FFFFFFFF'}};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF19856F'}};c.alignment={horizontal:'center'};row+=2;try{const ext=(e.receipt_mime||'image/jpeg').includes('png')?'png':'jpeg';const id=wb.addImage({base64:e.receipt_image_base64,extension:ext});ev.addImage(id,{tl:{col:1,row:row-1},ext:{width:420,height:540}});row+=29}catch{row+=2}}
    if(e.support_type?.includes('declaration')){ev.mergeCells(row,1,row,8);let c=ev.getCell(row,1);c.value='DECLARACIÓN JURADA DE GASTO DE TRANSPORTE';c.font={bold:true,color:{argb:'FFFFFFFF'},size:14};c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF17324D'}};c.alignment={horizontal:'center'};row+=2;const data=[['Fecha',formatDate(e.entry_date),'Monto',money(e.amount)],['Origen',e.origin||'—','Destino',e.destination||'—'],['Ingeniero',e.engineer_name||report.engineer_name||'—','Motivo',e.declaration_reason||'Servicio sin comprobante']];data.forEach(d=>{ev.getRow(row).values=d;ev.getRow(row).height=26;row++});ev.mergeCells(row,1,row+5,8);ev.getCell(row,1).value=declarationText(e,report);ev.getCell(row,1).alignment={wrapText:true,vertical:'middle'};row+=7;ev.mergeCells(row,1,row,8);ev.getCell(row,1).value=`Lugar y fecha de firma: ${e.declaration_place_date||'—'}`;ev.getCell(row,1).fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFFFF4CC'}};row+=2;if(e.signature_base64){try{const id=wb.addImage({base64:e.signature_base64,extension:'png'});ev.addImage(id,{tl:{col:1,row:row-1},ext:{width:180,height:75}})}catch{}}row+=6;ev.mergeCells(row,1,row,4);ev.getCell(row,1).value=`FIRMA DEL TRABAJADOR\n${report.owner_name}\nDNI ${report.owner_dni}`;ev.getCell(row,1).alignment={horizontal:'center',wrapText:true};ev.mergeCells(row,5,row,8);ev.getCell(row,5).value=`V.º B.º / FIRMA DEL INGENIERO\n${e.engineer_name||report.engineer_name||''}`;ev.getCell(row,5).alignment={horizontal:'center',wrapText:true};row+=4;}
  }
  const buffer=await wb.xlsx.writeBuffer();saveAs(new Blob([buffer],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}),`Reporte_Transporte_${formatDate(report.period_start).replaceAll('/','-')}.xlsx`)
}

function Empty(){return <div className="empty"><FileText size={42}/><h2>Aún no hay reportes</h2><p>Cuando sincronices un reporte desde la APK aparecerá aquí automáticamente.</p></div>}
createRoot(document.getElementById('root')).render(<App/>)
